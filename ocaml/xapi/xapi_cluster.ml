(*
 * Copyright (C) Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

open Xapi_clustering

module D = Debug.Make (struct let name = "xapi_cluster" end)

module Gencert = Gencertlib.Selfcert
open D

(* TODO: update allowed_operations on boot/toolstack-restart *)

let validate_params ~token_timeout ~token_timeout_coefficient =
  let invalid_value x y =
    raise Api_errors.(Server_error (invalid_value, [x; string_of_float y]))
  in
  if token_timeout < Constants.minimum_token_timeout_s then
    invalid_value "token_timeout" token_timeout ;
  if token_timeout_coefficient < Constants.minimum_token_timeout_coefficient_s
  then
    invalid_value "token_timeout_coefficient" token_timeout_coefficient

let create ~__context ~pIF ~cluster_stack ~pool_auto_join ~token_timeout
    ~token_timeout_coefficient =
  assert_cluster_stack_valid ~cluster_stack ;
  let cluster_stack_version =
    if Xapi_fist.allow_corosync2 () then
      2L
    else if not (Xapi_cluster_helpers.corosync3_enabled ~__context) then
      2L
    else
      3L
  in
  (* needed here in addtion to cluster_host.create_internal since the
     Xapi_clustering.daemon.enable relies on the correct corosync verion *)
  (* Currently we only support corosync. If we support more cluster stacks, this
   * should be replaced by a general function that checks the given cluster_stack *)
  Pool_features.assert_enabled ~__context ~f:Features.Corosync ;
  with_clustering_lock __LOC__ (fun () ->
      let dbg = Context.string_of_task_and_tracing __context in
      validate_params ~token_timeout ~token_timeout_coefficient ;
      let cluster_ref = Ref.make () in
      let cluster_host_ref = Ref.make () in
      let cluster_uuid = Uuidx.(to_string (make ())) in
      let cluster_host_uuid = Uuidx.(to_string (make ())) in
      (* For now we assume we have only one pool
         TODO: get master ref explicitly passed in as parameter*)
      let host = Helpers.get_master ~__context in
      let pifrec = Db.PIF.get_record ~__context ~self:pIF in
      assert_pif_prerequisites (pIF, pifrec) ;
      let open Cluster_interface in
      let ip_addr = ip_of_pif (pIF, pifrec) in
      let hostuuid = Inventory.lookup Inventory._installation_uuid in
      let hostname = Db.Host.get_hostname ~__context ~self:host in
      let member =
        Xapi_cluster_host_helpers.get_cluster_host_address ~__context ~ip_addr
          ~hostuuid ~hostname
      in
      let token_timeout_ms = Int64.of_float (token_timeout *. 1000.0) in
      let token_timeout_coefficient_ms =
        Int64.of_float (token_timeout_coefficient *. 1000.0)
      in
      let init_config =
        {
          member
        ; token_timeout_ms= Some token_timeout_ms
        ; token_coefficient_ms= Some token_timeout_coefficient_ms
        ; name= None
        ; cluster_stack=
            Cluster_stack.of_version (cluster_stack, cluster_stack_version)
        }
      in
      Xapi_clustering.Daemon.enable ~__context ;
      maybe_switch_cluster_stack_version ~__context ~self:cluster_host_ref
        ~cluster_stack:
          (Cluster_stack.of_version (cluster_stack, cluster_stack_version)) ;
      let result =
        Cluster_client.LocalClient.create (rpc ~__context) dbg init_config
      in
      match Idl.IdM.run @@ Cluster_client.IDL.T.get result with
      | Ok cluster_token ->
          D.debug "Got OK from LocalClient.create" ;
          Db.Cluster.create ~__context ~ref:cluster_ref ~uuid:cluster_uuid
            ~cluster_token ~cluster_stack ~cluster_stack_version
            ~pending_forget:[] ~pool_auto_join ~token_timeout
            ~token_timeout_coefficient ~current_operations:[]
            ~allowed_operations:[] ~cluster_config:[] ~other_config:[]
            ~is_quorate:false ~quorum:0L ~live_hosts:0L ~expected_hosts:0L ;
          Db.Cluster_host.create ~__context ~ref:cluster_host_ref
            ~uuid:cluster_host_uuid ~cluster:cluster_ref ~host ~enabled:true
            ~pIF ~current_operations:[] ~allowed_operations:[] ~other_config:[]
            ~joined:true ~live:true ~last_update_live:API.Date.epoch ;

          let verify = Stunnel_client.get_verify_by_default () in
          Xapi_cluster_host.set_tls_config ~__context ~self:cluster_host_ref
            ~verify ;
          (* Create the watcher here in addition to resync_host since pool_create
             in resync_host only calls cluster_host.create for pool member nodes *)
          Watcher.create_as_necessary ~__context ~host ;
          Xapi_cluster_host_helpers.update_allowed_operations ~__context
            ~self:cluster_host_ref ;
          D.debug "Created Cluster: %s and Cluster_host: %s"
            (Ref.string_of cluster_ref)
            (Ref.string_of cluster_host_ref) ;
          set_ha_cluster_stack ~__context ;
          cluster_ref
      | Error error ->
          D.warn
            "Error occurred during Cluster.create. Shutting down cluster daemon" ;
          Xapi_clustering.Watcher.signal_exit () ;
          Xapi_clustering.Daemon.disable ~__context ;
          handle_error error
  )

let destroy ~__context ~self =
  let cluster_hosts = Db.Cluster.get_cluster_hosts ~__context ~self in
  let cluster_host =
    match cluster_hosts with
    | [] ->
        info "No cluster_hosts found. Proceeding with cluster destruction." ;
        None
    | [cluster_host] ->
        Some cluster_host
    | _ ->
        let n = List.length cluster_hosts in
        raise
          Api_errors.(
            Server_error (cluster_does_not_have_one_node, [string_of_int n])
          )
  in
  Option.iter
    (fun ch ->
      assert_cluster_host_has_no_attached_sr_which_requires_cluster_stack
        ~__context ~self:ch ;
      Xapi_cluster_host.force_destroy ~__context ~self:ch
    )
    cluster_host ;
  Db.Cluster.destroy ~__context ~self ;
  D.debug "Cluster destroyed successfully" ;
  set_ha_cluster_stack ~__context ;
  Xapi_clustering.Watcher.signal_exit () ;
  Xapi_clustering.Daemon.disable ~__context

(* Get pool master's cluster_host, return network of PIF *)
let get_network ~__context ~self = get_network_internal ~__context ~self

(** Cluster.pool* functions are convenience wrappers for iterating low-level APIs over a pool.
    Concurrency checks are done in the implementation of these calls *)

let foreach_cluster_host ~__context ~self:_
    ~(fn :
          rpc:(Rpc.call -> Rpc.response)
       -> session_id:API.ref_session
       -> self:API.ref_Cluster_host
       -> unit
       ) ~log =
  let wrapper = if log then log_and_ignore_exn else fun f -> f () in
  List.iter (fun self ->
      Helpers.call_api_functions ~__context (fun rpc session_id ->
          wrapper (fun () -> fn ~rpc ~session_id ~self)
      )
  )

let pool_destroy_common ~__context ~self ~force =
  (* Prevent new hosts from joining if destroy fails *)
  Db.Cluster.set_pool_auto_join ~__context ~self ~value:false ;
  let slave_cluster_hosts =
    let all_hosts = Db.Cluster.get_cluster_hosts ~__context ~self in
    let master = Helpers.get_master ~__context in
    match Xapi_clustering.find_cluster_host ~__context ~host:master with
    | None ->
        all_hosts
    | Some master_ch ->
        List.filter (( <> ) master_ch) all_hosts
  in
  foreach_cluster_host ~__context ~self ~log:force
    ~fn:Client.Client.Cluster_host.destroy slave_cluster_hosts

let pool_force_destroy ~__context ~self =
  (* Set pool_autojoin:false and try to destroy slave cluster_hosts *)
  pool_destroy_common ~__context ~self ~force:true ;
  (* Note we include the master here, we should attempt to force destroy it *)
  (* Now try to force_destroy, keep track of any errors here *)
  debug "Ignoring exceptions while trying to force destroy cluster hosts." ;
  foreach_cluster_host ~__context ~self ~log:true
    ~fn:Client.Client.Cluster_host.force_destroy
    (Db.Cluster.get_cluster_hosts ~__context ~self) ;
  info "Forgetting any cluster_hosts that couldn't be destroyed." ;
  foreach_cluster_host ~__context ~self ~log:true
    ~fn:Client.Client.Cluster_host.forget
    (Db.Cluster.get_cluster_hosts ~__context ~self) ;
  let unforgotten_cluster_hosts =
    List.filter
      (fun self -> not (Db.Cluster_host.get_joined ~__context ~self))
      (Db.Cluster.get_cluster_hosts ~__context ~self)
  in
  info "We now delete completely the cluster_hosts where forget failed" ;
  foreach_cluster_host ~__context ~self ~log:false
    ~fn:(fun ~rpc:_ ~session_id:_ ~self ->
      Db.Cluster_host.destroy ~__context ~self
    )
    unforgotten_cluster_hosts ;
  match Db.Cluster.get_cluster_hosts ~__context ~self with
  | [] ->
      D.debug
        "Successfully destroyed all cluster_hosts in pool, now destroying \
         cluster %s"
        (Ref.string_of self) ;
      Helpers.call_api_functions ~__context (fun rpc session_id ->
          Client.Client.Cluster.destroy ~rpc ~session_id ~self
      ) ;
      debug "Cluster.pool_force_destroy was successful"
  | _ ->
      raise
        Api_errors.(
          Server_error (cluster_force_destroy_failed, [Ref.string_of self])
        )

let pool_destroy ~__context ~self =
  (* Set pool_autojoin:false and try to destroy slave cluster_hosts *)
  pool_destroy_common ~__context ~self ~force:false ;
  (* Then destroy the Cluster_host of the pool master and the Cluster itself *)
  Helpers.call_api_functions ~__context (fun rpc session_id ->
      Client.Client.Cluster.destroy ~rpc ~session_id ~self
  )

let pool_create ~__context ~network ~cluster_stack ~token_timeout
    ~token_timeout_coefficient =
  validate_params ~token_timeout ~token_timeout_coefficient ;
  let master = Helpers.get_master ~__context in
  let slave_hosts = Xapi_pool_helpers.get_slaves_list ~__context in
  let pIF, _ = pif_of_host ~__context network master in
  let cluster =
    Helpers.call_api_functions ~__context (fun rpc session_id ->
        Client.Client.Cluster.create ~rpc ~session_id ~pIF ~cluster_stack
          ~pool_auto_join:true ~token_timeout ~token_timeout_coefficient
    )
  in
  try
    List.iter
      (fun host ->
        (* Cluster.create already created cluster_host on master, so we only iterate through slaves *)
        Helpers.call_api_functions ~__context (fun rpc session_id ->
            let pif, _ = pif_of_host ~__context network host in
            let cluster_host_ref =
              Client.Client.Cluster_host.create ~rpc ~session_id ~cluster ~host
                ~pif
            in
            D.debug "Created Cluster_host: %s" (Ref.string_of cluster_host_ref)
        )
      )
      slave_hosts ;
    cluster
  with e ->
    error "pool_create failed. exception='%s'" (Printexc.to_string e) ;
    info "pool_create attempting cleanup of cluster=%s"
      (Ref.short_string_of cluster) ;
    ( try pool_force_destroy ~__context ~self:cluster
      with e ->
        error "pool_create attempt to clean up cluster=%s failed. ex='%s'"
          (Ref.short_string_of cluster)
          (Printexc.to_string e)
    ) ;
    raise e

(* Work is split between message_forwarding and this code. This code is
   executed on each host locally *)
let pool_resync ~__context ~self:_ =
  let host = Helpers.get_localhost ~__context in
  log_and_ignore_exn @@ fun () ->
  Xapi_cluster_host.create_as_necessary ~__context ~host ;
  Xapi_cluster_host.resync_host ~__context ~host ;
  if is_clustering_disabled_on_host ~__context host then
    raise
      Api_errors.(
        Server_error (no_compatible_cluster_host, [Ref.string_of host])
      )
(* If host.clustering_enabled then resync_host should successfully
   find or create a matching cluster_host which is also enabled *)

let cstack_sync ~__context ~self =
  debug "%s: sync db data with cluster stack" __FUNCTION__ ;
  Watcher.on_corosync_update ~__context ~cluster:self
    ["Updates due to cluster api calls"]

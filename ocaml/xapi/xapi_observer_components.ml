(*
 * Copyright (C) 2023 Cloud Software Group
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

module D = Debug.Make (struct let name = "xapi_observer_components" end)

type t = Xapi | Xenopsd | Xapi_clusterd | SMApi | Xapi_storage_script
[@@deriving ord]

exception Unsupported_Component of string

let to_string = function
  | Xapi ->
      Constants.observer_component_xapi
  | Xenopsd ->
      Constants.observer_component_xenopsd
  | Xapi_clusterd ->
      Constants.observer_component_xapi_clusterd
  | SMApi ->
      Constants.observer_component_smapi
  | Xapi_storage_script ->
      Constants.observer_component_xapi_storage_script

let of_string = function
  | str when String.equal str Constants.observer_component_xapi ->
      D.info "Getting Xapi component of string" ;
      Xapi
  | str when String.equal str Constants.observer_component_xenopsd ->
      D.info "Getting xenops component of string" ;
      Xenopsd
  | str when String.equal str Constants.observer_component_xapi_clusterd ->
      D.info "Getting cluster component of string" ;
      Xapi_clusterd
  | str when String.equal str Constants.observer_component_smapi ->
      D.info "Getting smapi component of string" ;
      SMApi
  | str when String.equal str Constants.observer_component_xapi_storage_script
    ->
      D.info "Getting xapi_storage_script component of string" ;
      Xapi_storage_script
  | c ->
      raise (Unsupported_Component c)

let all = List.map of_string Constants.observer_components_all

(* We start up the observer for clusterd only if clusterd has been enabled
   otherwise we initialise clusterd separately in cluster_host so that
   there is no need to restart xapi in order for clusterd to be observed.
   This does mean that observer will always be enabled for clusterd. *)
let startup_components () =
  List.filter
    (function
      | Xapi_clusterd -> Xapi_clustering.Daemon.is_enabled () | _ -> true
      )
    all

let assert_valid_components components =
  try List.iter (fun c -> ignore @@ of_string c) components
  with Unsupported_Component component ->
    raise Api_errors.(Server_error (invalid_value, ["component"; component]))

let filter_out_exp_components components =
  let open Xapi_globs in
  let component_set = components |> List.map to_string |> StringSet.of_list in
  let experimental_list = !observer_experimental_components |> StringSet.elements in
  D.info "experimental components list=%s" (String.concat ", " experimental_list) ;
  let component_list = StringSet.diff component_set !observer_experimental_components
  |> StringSet.elements
  in
  D.info "filter_out_exp_components list=%s" (String.concat ", " component_list) ;
  component_list |> List.map of_string

let observed_components_of components =
  let result = ( match components with
  | [] ->
      startup_components ()
  | components ->
      components
  )
  |> filter_out_exp_components in
  let component_list = result |> List.map to_string in
  D.info "observed_components_of=%s" (String.concat ", " component_list) ;
  result

let is_component_enabled ~component =
  try
    Server_helpers.exec_with_new_task
      (Printf.sprintf "check if component %s is enabled " (to_string component))
      (fun __context ->
        try
          let observers = Db.Observer.get_all ~__context in
          List.exists
            (fun observer ->
              Db.Observer.get_enabled ~__context ~self:observer
              && Db.Observer.get_components ~__context ~self:observer
                 |> List.map of_string
                 |> observed_components_of
                 |> List.mem component
            )
            observers
        with e ->
          D.log_backtrace () ;
          D.warn "is_component_enabled(%s) inner got exception: %s"
            (to_string component) (Printexc.to_string e) ;
          false
      )
  with e ->
    D.log_backtrace () ;
    D.warn "is_component_enabled(%s) got exception: %s" (to_string component)
      (Printexc.to_string e) ;
    false

let is_smapi_enabled () = is_component_enabled ~component:SMApi

let ( // ) = Filename.concat

let dir_name_of_component component =
  Xapi_globs.observer_config_dir // to_string component // "enabled"

let env_exe_args_of ~env_vars ~component ~exe ~args =
  let dir_name_value = Filename.quote (dir_name_of_component component) in
  let new_env_vars =
    Array.concat
      [
        env_vars
      ; Env_record.to_string_array
          [
            Env_record.pair ("OBSERVER_CONFIG_DIR", dir_name_value)
          ; Env_record.pair ("PYTHONPATH", Filename.dirname exe)
          ]
      ]
  in
  let args = "-m" :: "observer" :: exe :: args in
  let new_exe = Xapi_globs.python3_path in
  (Some new_env_vars, new_exe, args)

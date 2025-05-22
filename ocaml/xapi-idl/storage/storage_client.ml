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

open Storage_interface
open Xcp_client
module D = Debug.Make (struct let name = service_name end)
open D

let rec retry_econnrefused f =
  try f () with
  | Unix.Unix_error (Unix.ECONNREFUSED, "connect", _) ->
      (* debug "Caught ECONNREFUSED; retrying in 5s"; *)
      Thread.delay 5. ; retry_econnrefused f
  | e ->
      (* error "Caught %s: does the storage service need restarting?"
         (Printexc.to_string e); *)
      raise e

module Client = Storage_interface.StorageAPI (Idl.Exn.GenClient (struct
  let rpc call =
    retry_econnrefused (fun () ->
        info "storage_client Client" ;
        if !use_switch then (
          info "Client json_switch_rpc" ;
          json_switch_rpc !queue_name call
        ) else (
          info "Client xml_http_rpc" ;
          xml_http_rpc ~srcstr:(get_user_agent ()) ~dststr:"storage"
            Storage_interface.uri call
        )
    )
end))

module ObserverClient = Observer_helpers.ObserverAPI
  (Idl.Exn.GenClient (struct
    let rpc call =
      retry_econnrefused (fun () ->
          info "storage_client ObserverClient" ;
          (* Hardcoded for testing *)
          let queue_name = (Xcp_service.common_prefix ^ ".smapiv3-observer") in
          if !use_switch then (
            info "ObserverClient json_switch_rpc" ;
            json_switch_rpc queue_name call
          ) else (
            info "ObserverClient xml_http_rpc" ;
            (* Hardcoded for testing *)
            xml_http_rpc ~srcstr:(get_user_agent ()) ~dststr:queue_name
              (fun () -> "file:/var/lib/xcp/storage.d/smapiv3-observer") call
          )
      )
  end))

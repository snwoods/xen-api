(*
 * Copyright (C) 2006-2009 Citrix Systems Inc.
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
(** Common code between the fake and real servers for dealing with VIFs.
 * @group Networking
*)

val assert_operation_valid :
  __context:Context.t -> self:[`VIF] Ref.t -> op:API.vif_operations -> unit
(** Throw error if the given operation is not in the list of allowed operations. *)

val update_allowed_operations : __context:Context.t -> self:[`VIF] Ref.t -> unit
(** Update the [PIF.allowed_operations] field. *)

val cancel_tasks :
     __context:Context.t
  -> self:[`VIF] Ref.t
  -> all_tasks_in_db:API.ref_task list
  -> task_ids:string list
  -> unit
(** Cancel all current operations. *)

val clear_current_operations : __context:Context.t -> self:[`VIF] Ref.t -> unit
(** Empty the [PIF.current_operations] field. *)

val assert_locking_licensed : __context:Context.t -> unit

val create :
     __context:Context.t
  -> device:string
  -> network:[`network] Ref.t
  -> vM:[`VM] Ref.t
  -> mAC:string
  -> mTU:int64
  -> other_config:(string * string) list
  -> qos_algorithm_type:string
  -> qos_algorithm_params:(string * string) list
  -> currently_attached:bool
  -> locking_mode:API.vif_locking_mode
  -> ipv4_allowed:string list
  -> ipv6_allowed:string list
  -> ipv4_configuration_mode:[< `None | `Static]
  -> ipv4_addresses:string list
  -> ipv4_gateway:string
  -> ipv6_configuration_mode:[< `None | `Static]
  -> ipv6_addresses:string list
  -> ipv6_gateway:string
  -> API.ref_VIF
(** Create a VIF object in the database. *)

val destroy : __context:Context.t -> self:[`VIF] Ref.t -> unit
(** Destroy a VIF object in the database. *)

val copy :
     __context:Context.t
  -> vm:[`VM] Ref.t
  -> preserve_mac_address:bool
  -> [`VIF] Ref.t
  -> API.ref_VIF
(** Copy a VIF. *)

val gen_mac : int * string -> string
(** Generate a MAC address *)

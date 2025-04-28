open Xenops_utils

module D = Debug.Make (struct let name = __MODULE__ end)

module XI = struct
  include Xenops_interface

  let cancelled s = Xenopsd_error (Errors.Cancelled s)

  let does_not_exist (x, y) = Xenopsd_error (Errors.Does_not_exist (x, y))

  let marshal_exn e =
    match e with
    | Xenopsd_error e' ->
        Rpcmarshal.marshal Errors.error.Rpc.Types.ty e'
    | _ ->
        Rpcmarshal.marshal Errors.error.Rpc.Types.ty
          (Errors.Internal_error (Printexc.to_string e))
end

module Xenops_task = Task_server.Task (XI)
module Updates = Updates.Updates (XI)

let scheduler = Scheduler.make ()

let updates = Updates.empty scheduler

let tasks = Xenops_task.empty ()

(* [event_wait local_updates task ~from ~timeout_start timeout filter p] waits
   for an event in the queue [local_updates] after event [from] until
   [timeout_start + timeout] that matches [filter] and makes [p] return [true],
   then returns it, otherwise returns None when the timeout is reached. This
   can be interrupted by cancelling the task [task]. *)
let event_wait local_updates task ?from ?timeout_start timeout filter p =
  let start =
    match timeout_start with Some s -> s | None -> Unix.gettimeofday ()
  in
  let rec inner remaining event_id =
    if remaining > 0.0 then
      let _, deltas, next_id =
        Updates.get
          (Printf.sprintf "event_wait task %s" (Xenops_task.id_of_handle task))
          ~with_cancel:(Xenops_task.with_cancel task)
          event_id
          (Some (remaining |> ceil |> int_of_float))
          local_updates
      in
      match List.find_map filter deltas with
      | Some found when p found ->
          Some found
      | Some _ | None ->
          (* no matching events found by Updates.get, retry *)
          let elapsed = Unix.gettimeofday () -. start in
          inner (timeout -. elapsed) (Some next_id)
    else (* timeout reached *)
      None
  in
  let result = inner timeout from in
  Xenops_task.check_cancelling task ;
  result

let task_ended = function
  | Xenops_interface.Task.Completed _ | Failed _ ->
      true
  | Pending _ ->
      false

let is_task task = function
  | Xenops_interface.Dynamic.Task id when id = task ->
      Some Xenops_task.(get_state (handle_of_id tasks id))
  | _ ->
      None

let parallel_id_with_tracing parallel_id t =
  Debug_info.make ~log:parallel_id ~tracing:(Xenops_task.tracing t)
  |> Debug_info.to_string

let dbg_with_traceparent_of_task t =
  Debug_info.make ~log:(Xenops_task.get_dbg t) ~tracing:(Xenops_task.tracing t)
  |> Debug_info.to_string

let traceparent_header_of_task t =
  Option.map
    (fun tracing ->
      ( "traceparent"
      , tracing
        |> Tracing.Span.get_context
        |> Tracing.SpanContext.to_traceparent
      )
    )
    (Xenops_task.tracing t)
  |> Option.to_list

let with_tracing ~name ~task f =
  let open Tracing in
  let parent = Xenops_task.tracing task in
  let tracer = Tracer.get_tracer ~name in
  match Tracer.start ~tracer ~name ~parent () with
  | Ok span -> (
      Xenops_task.set_tracing task span ;
      try
        let result = f () in
        let _ : (Span.t option, exn) result = Tracer.finish span in
        Xenops_task.set_tracing task parent ;
        result
      with exn ->
        let backtrace = Printexc.get_raw_backtrace () in
        let error = (exn, backtrace) in
        let _ : (Span.t option, exn) result = Tracer.finish span ~error in
        raise exn
    )
  | Error e ->
      D.warn "Failed to start tracing: %s" (Printexc.to_string e) ;
      f ()

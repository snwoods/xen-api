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
let with_lock = Xapi_stdext_threads.Threadext.Mutex.execute

let finally = Xapi_stdext_pervasives.Pervasiveext.finally

open Event_types

module D = Debug.Make (struct let name = "xapi_event" end)

open D

module Message = struct
  type t =
    | Create of (API.ref_message * API.message_t)
    | Del of API.ref_message

  let get_since_for_events :
      (__context:Context.t -> int64 -> int64 * t list) ref =
    ref (fun ~__context _ -> ignore __context ; (0L, []))
end

module Token = struct
  exception Failed_to_parse of string

  let of_string token =
    match String.split_on_char ',' token with
    | [from; from_t] ->
        (Int64.of_string from, Int64.of_string from_t)
    | [""] ->
        (0L, 0L)
    | _ ->
        raise (Failed_to_parse token)

  let to_string (last, last_t) =
    (* We prefix with zeroes so tokens which differ only in the generation
       		   can be compared lexicographically as strings. *)
    Printf.sprintf "%020Ld,%020Ld" last last_t
end

let is_lowercase_char c = Char.equal (Char.lowercase_ascii c) c

let is_lowercase str = String.for_all is_lowercase_char str

module Subscription = struct
  type t = Class of string | Object of string * string | All

  let is_task_only = function
    | Class "task" | Object ("task", _) ->
        true
    | Class _ | Object _ | All ->
        false

  let of_string x =
    if x = "*" then
      All
    else
      match Xapi_stdext_std.Xstringext.String.split ~limit:2 '/' x with
      | [cls] ->
          Class (String.lowercase_ascii cls)
      | [cls; id] ->
          Object (String.lowercase_ascii cls, id)
      | _ ->
          raise
            (Api_errors.Server_error
               (Api_errors.event_subscription_parse_failure, [x])
            )

  (** [table_matches subs tbl]: true if at least one subscription from [subs] would select some events from [tbl] *)
  let table_matches subs tbl =
    let tbl = if is_lowercase tbl then tbl else String.lowercase_ascii tbl in
    let matches = function
      | All ->
          true
      | Class x ->
          x = tbl
      | Object (x, _) ->
          x = tbl
    in
    List.exists matches subs

  (** [event_matches subs ev]: true if at least one subscription from [subs] selects for specified class and object *)
  let object_matches subs ty _ref =
    let tbl = if is_lowercase ty then ty else String.lowercase_ascii ty in
    let matches = function
      | All ->
          true
      | Class x ->
          x = tbl
      | Object (x, y) ->
          x = tbl && y = _ref
    in
    List.exists matches subs

  (** [event_matches subs ev]: true if at least one subscription from [subs] selects for event [ev] *)
  let event_matches subs ev = object_matches subs ev.ty ev.reference
end

module Next = struct
  (* Infrastructure for the deprecated Event.next *)

  (** Limit the event queue to this many events: *)
  let max_queue_size = 10000000

  let old_max_queue_length = 500

  (** Ordered list of events, newest first *)
  let queue = ref []

  (** Monotonically increasing event ID. One higher than the highest event ID in the queue *)
  let id = ref 0L

  (** When we GC events we track how many we've deleted so we can send an error to the client *)
  let highest_forgotten_id = ref (-1L)

  type subscription = {
      mutable last_id: int64  (** last event ID to sent to this client *)
    ; mutable subs: Subscription.t list  (** all the subscriptions *)
    ; m: Mutex.t  (** protects access to the mutable fields in this record *)
    ; session: API.ref_session  (** session which owns this subscription *)
    ; mutable session_invalid: bool
          (** set to true if the associated session has been deleted *)
  }

  (* For Event.next, the single subscription associated with a session *)
  let subscriptions : (API.ref_session, subscription) Hashtbl.t =
    Hashtbl.create 10

  let m = Mutex.create ()

  let c = Condition.create ()

  let event_size ev =
    let rpc = rpc_of_event ev in
    let string = Jsonrpc.to_string rpc in
    String.length string

  (* Add an event to the queue if it matches any active subscriptions *)
  let add ev =
    with_lock m (fun () ->
        let matches =
          Hashtbl.fold
            (fun _ s acc ->
              if Subscription.event_matches s.subs ev then
                true
              else
                acc
            )
            subscriptions false
        in
        if matches then (
          let size = event_size ev in
          queue := (size, ev) :: !queue ;
          (* debug "Adding event %Ld: %s" (!id) (string_of_event ev); *)
          id := Int64.add !id Int64.one ;
          Condition.broadcast c
        ) else
          ( (* debug "Dropping event %s" (string_of_event ev) *) ) ;
        (* GC the events in the queue *)
        let total_size =
          List.fold_left (fun acc (sz, _) -> acc + sz) 0 !queue
        in
        let too_many = total_size > max_queue_size in
        let to_keep, to_drop =
          if not too_many then
            (!queue, [])
          else
            (* Reverse-sort by ID and preserve only enough events such that the total
               			       size does not exceed 'max_queue_size' *)
            let sorted =
              List.sort
                (fun (_, a) (_, b) ->
                  compare (Int64.of_string b.id) (Int64.of_string a.id)
                )
                !queue
            in
            let _total_size_after, rev_to_keep, rev_to_drop =
              List.fold_left
                (fun (tot_size, keep, drop) (size, elt) ->
                  if tot_size + size < max_queue_size then
                    (tot_size + size, (size, elt) :: keep, drop)
                  else
                    (tot_size + size, keep, (size, elt) :: drop)
                )
                (0, [], []) sorted
            in
            let to_keep = List.rev rev_to_keep in
            let to_drop = List.rev rev_to_drop in
            if List.length to_keep < old_max_queue_length then
              warn
                "Event queue length degraded. Number of events kept: %d (less \
                 than old_max_queue_length=%d)"
                (List.length to_keep) old_max_queue_length ;
            (to_keep, to_drop)
        in
        queue := to_keep ;
        (* Remember the highest ID of the list of events to drop *)
        if to_drop <> [] then
          highest_forgotten_id := Int64.of_string (snd (List.hd to_drop)).id
        (* debug "After event queue GC: keeping %d; dropping %d (highest dropped id = %Ld)"
           			(List.length to_keep) (List.length to_drop) !highest_forgotten_id *)
    )

  let assert_subscribed session =
    with_lock m (fun () ->
        if not (Hashtbl.mem subscriptions session) then
          raise
            (Api_errors.Server_error
               ( Api_errors.session_not_registered
               , [Context.trackid_of_session (Some session)]
               )
            )
    )

  (* Fetch the single subscription_record associated with a session or create
     	   one if one doesn't exist already *)
  let get_subscription session =
    with_lock m (fun () ->
        match Hashtbl.find_opt subscriptions session with
        | Some x ->
            x
        | None ->
            let subscription =
              {
                last_id= !id
              ; subs= []
              ; m= Mutex.create ()
              ; session
              ; session_invalid= false
              }
            in
            Hashtbl.replace subscriptions session subscription ;
            subscription
    )

  let on_session_deleted session_id =
    with_lock m (fun () ->
        let mark_invalid sub =
          (* Mark the subscription as invalid and wake everyone up *)
          with_lock sub.m (fun () -> sub.session_invalid <- true) ;
          Condition.broadcast c
        in
        Option.iter
          (fun sub ->
            mark_invalid sub ;
            Hashtbl.remove subscriptions session_id
          )
          (Hashtbl.find_opt subscriptions session_id)
    )

  let session_is_invalid sub = with_lock sub.m (fun () -> sub.session_invalid)

  (* Blocks the caller until the current ID has changed OR the session has been
     	    invalidated. *)
  let wait subscription from_id =
    let result = ref 0L in
    with_lock m (fun () ->
        (* NB we occasionally grab the specific session lock while holding the general lock *)
        while !id = from_id && not (session_is_invalid subscription) do
          Condition.wait c m
        done ;
        result := !id
    ) ;
    if session_is_invalid subscription then
      raise
        (Api_errors.Server_error
           (Api_errors.session_invalid, [Ref.string_of subscription.session])
        )
    else
      !result

  (* Thrown if the user requests events which we don't have because we've thrown
     	   then away. This should only happen if more than max_stored_events are produced
     	   between successive calls to Event.next (). The client should refresh all its state
     	   manually before calling Event.next () again.
  *)
  let events_lost () =
    raise (Api_errors.Server_error (Api_errors.events_lost, []))

  (* Return events from the queue between a start and an end ID. Throws
     	   an API error if some events have been lost, signalling the client to
     	   re-register. *)
  let events_read id_start id_end =
    let check_ev ev =
      id_start <= Int64.of_string ev.id && Int64.of_string ev.id < id_end
    in
    let some_events_lost = ref false in
    let selected_events =
      with_lock m (fun () ->
          some_events_lost := !highest_forgotten_id >= id_start ;
          List.find_all (fun (_, ev) -> check_ev ev) !queue
      )
    in
    (* Note we may actually retrieve fewer events than we expect because the
       		   queue may have been coalesced. *)
    if !some_events_lost (* is true *) then events_lost () ;
    (* NB queue is kept in reverse order *)
    List.map snd (List.rev selected_events)
end

module From = struct
  let m = Mutex.create ()

  let c = Condition.create ()

  let next_index =
    let id = ref 0L in
    fun () ->
      with_lock m (fun () ->
          let result = !id in
          id := Int64.succ !id ;
          result
      )

  (* A (blocking) call which should be unblocked on logout *)
  type call = {
      index: int64
    ; (* Unique id for this call *)
      mutable cur_id: int64
    ; (* Most current generation count relevant to the client *)
      subs: Subscription.t list
    ; (* list of all the subscriptions *)
      session: API.ref_session
    ; (* the session associated with this call *)
      mutable session_invalid: bool
    ; (* set to true if the associated session has been deleted *)
      m: Mutex.t (* protects access to the mutable fields in this record *)
  }

  (* The set of (blocking) calls associated with a session *)
  let calls : (API.ref_session, call list) Hashtbl.t = Hashtbl.create 10

  let get_current_event_number () =
    let open Xapi_database in
    Db_cache_types.Manifest.generation
      (Db_cache_types.Database.manifest
         (Db_ref.get_database (Db_backend.make ()))
      )

  (* Add an event to the queue if it matches any active subscriptions *)
  let add ev =
    with_lock m (fun () ->
        let matches_per_thread =
          Hashtbl.fold
            (fun _ s acc ->
              List.fold_left
                (fun acc s ->
                  if Subscription.event_matches s.subs ev then (
                    s.cur_id <- get_current_event_number () ;
                    true
                  ) else
                    acc
                )
                acc s
            )
            calls false
        in
        if matches_per_thread then Condition.broadcast c
    )

  (* Call a function with a registered call which will be woken up if
     	   the session is destroyed in the background. *)
  let with_call session subs f =
    let index = next_index () in
    let fresh =
      {
        index
      ; cur_id= 0L
      ; subs
      ; m= Mutex.create ()
      ; session
      ; session_invalid= false
      }
    in
    with_lock m (fun () ->
        let existing =
          Option.value (Hashtbl.find_opt calls session) ~default:[]
        in
        Hashtbl.replace calls session (fresh :: existing)
    ) ;
    finally
      (fun () -> f fresh)
      (fun () ->
        with_lock m (fun () ->
            Option.iter
              (fun existing ->
                let remaining =
                  List.filter (fun x -> not (x.index = fresh.index)) existing
                in
                if remaining = [] then
                  Hashtbl.remove calls session
                else
                  Hashtbl.replace calls session remaining
              )
              (Hashtbl.find_opt calls session)
        )
      )

  (* Is called by the session timeout code *)
  let on_session_deleted session_id =
    with_lock m (fun () ->
        let mark_invalid sub =
          (* Mark the subscription as invalid and wake everyone up *)
          with_lock sub.m (fun () -> sub.session_invalid <- true) ;
          Condition.broadcast c
        in
        Option.iter
          (fun x ->
            List.iter mark_invalid x ;
            Hashtbl.remove calls session_id
          )
          (Hashtbl.find_opt calls session_id)
    )

  let session_is_invalid call = with_lock call.m (fun () -> call.session_invalid)

  let wait2 call from_id timer =
    let timeoutname = Printf.sprintf "event_from_timeout_%Ld" call.index in
    with_lock m (fun () ->
        while
          from_id = call.cur_id
          && (not (session_is_invalid call))
          && not (Clock.Timer.has_expired timer)
        do
          match Clock.Timer.remaining timer with
          | Expired _ ->
              ()
          | Remaining delta ->
              Xapi_stdext_threads_scheduler.Scheduler.add_to_queue_span
                timeoutname Xapi_stdext_threads_scheduler.Scheduler.OneShot
                delta (fun () -> Condition.broadcast c
              ) ;
              Condition.wait c m ;
              Xapi_stdext_threads_scheduler.Scheduler.remove_from_queue
                timeoutname
        done
    ) ;
    if session_is_invalid call then (
      info "%s raising SESSION_INVALID *because* subscription is invalid"
        (Context.trackid_of_session (Some call.session)) ;
      raise
        (Api_errors.Server_error
           (Api_errors.session_invalid, [Ref.string_of call.session])
        )
    )
end

(** Register an interest in events generated on objects of class <class_name> *)
let register ~__context ~classes =
  let session = Context.get_session_id __context in
  let open Next in
  let subs = List.map Subscription.of_string classes in
  let sub = Next.get_subscription session in
  with_lock sub.m (fun () -> sub.subs <- subs @ sub.subs)

(** Unregister interest in events generated on objects of class <class_name> *)
let unregister ~__context ~classes =
  let session = Context.get_session_id __context in
  let open Next in
  let subs = List.map Subscription.of_string classes in
  let sub = Next.get_subscription session in
  with_lock sub.m (fun () ->
      sub.subs <- List.filter (fun x -> not (List.mem x subs)) sub.subs
  )

(** Blocking call which returns the next set of events relevant to this session. *)
let rec next ~__context =
  let batching =
    if !Constants.use_event_next then
      Throttle.Batching.make ~delay_before:Mtime.Span.zero
        ~delay_between:Mtime.Span.zero
    else
      !Xapi_globs.event_next_delay
  in
  let session = Context.get_session_id __context in
  let open Next in
  assert_subscribed session ;
  let subscription = get_subscription session in
  (* Return a <from_id, end_id> exclusive range that is guaranteed to be specific to this
     	   thread. Concurrent calls will grab wholly disjoint ranges. Note the range might be
     	   empty. *)
  let grab_range () =
    (* Briefly hold both the general and the specific mutex *)
    with_lock m (fun () ->
        with_lock subscription.m (fun () ->
            let last_id = subscription.last_id in
            (* Bump our last_id counter: these events don't have to be looked at again *)
            subscription.last_id <- !id ;
            (last_id, !id)
        )
    )
  in
  (* Like grab_range () only guarantees to return a non-empty range by blocking if necessary *)
  let grab_nonempty_range =
    Throttle.Batching.with_recursive_loop batching @@ fun self arg ->
    let last_id, end_id = grab_range () in
    if last_id = end_id then
      let (_ : int64) = wait subscription end_id in
      (self [@tailcall]) arg
    else
      (last_id, end_id)
  in
  let last_id, end_id = grab_nonempty_range () in
  (* debug "next examining events in range %Ld <= x < %Ld" last_id end_id; *)
  (* Are any of the new events interesting? *)
  let events = events_read last_id end_id in
  let subs = with_lock subscription.m (fun () -> subscription.subs) in
  let relevant =
    List.filter (fun ev -> Subscription.event_matches subs ev) events
  in
  (* debug "number of relevant events = %d" (List.length relevant); *)
  if relevant = [] then
    next ~__context
  else
    rpc_of_events relevant

type time = Xapi_database.Db_cache_types.Time.t

type entry = {table: string; obj: string; time: time}

type acc = {
    creates: entry list
  ; mods: entry list
  ; deletes: entry list
  ; last: time
}

let collect_events (subs, tables, last_generation) acc table =
  let open Xapi_database in
  let open Db_cache_types in
  let table_value = TableSet.find table tables in
  let prepend_recent obj stat _ ({creates; mods; last; _} as entries) =
    let Stat.{created; modified; deleted} = stat in
    if Subscription.object_matches subs table obj then
      let last = max last (max modified deleted) in
      let creates =
        if created > last_generation then
          {table; obj; time= created} :: creates
        else
          creates
      in
      let mods =
        if modified > last_generation && not (created > last_generation) then
          {table; obj; time= modified} :: mods
        else
          mods
      in
      {entries with creates; mods; last}
    else
      entries
  in
  let prepend_deleted obj stat ({deletes; last; _} as entries) =
    let Stat.{created; modified; deleted} = stat in
    if Subscription.object_matches subs table obj then
      let last = max last (max modified deleted) in
      let deletes =
        if created <= last_generation then
          {table; obj; time= deleted} :: deletes
        else
          deletes
      in
      {entries with deletes; last}
    else
      entries
  in
  acc
  |> Table.fold_over_recent last_generation prepend_recent table_value
  |> Table.fold_over_deleted last_generation prepend_deleted table_value

let from_inner __context session subs from from_t timer batching =
  let open Xapi_database in
  let open From in
  (* The database tables involved in our subscription *)
  let tables =
    let all =
      let objs =
        List.filter
          (fun x -> x.Datamodel_types.gen_events)
          (Dm_api.objects_of_api Datamodel.all_api)
      in
      let objs = List.map (fun x -> x.Datamodel_types.name) objs in
      objs
    in
    List.filter (fun table -> Subscription.table_matches subs table) all
  in
  let last_msg_gen = ref from_t in
  let grab_range ~since t =
    let tableset = Db_cache_types.Database.tableset (Db_ref.get_database t) in
    let msg_gen, messages =
      if Subscription.table_matches subs "message" then
        !Message.get_since_for_events ~__context !last_msg_gen
      else
        (0L, [])
    in
    let events =
      let initial = {creates= []; mods= []; deletes= []; last= since} in
      let folder = collect_events (subs, tableset, since) in
      List.fold_left folder initial tables
    in
    (msg_gen, messages, tableset, events)
  in
  (* Each event.from should have an independent subscription record *)
  let msg_gen, messages, tableset, events =
    with_call session subs (fun sub ->
        let grab_nonempty_range =
          Throttle.Batching.with_recursive_loop batching @@ fun self since ->
          let result =
            Db_lock.with_lock (fun () -> grab_range ~since (Db_backend.make ()))
          in
          let msg_gen, messages, _tables, events = result in
          let {creates; mods; deletes; last} = events in
          if
            creates = []
            && mods = []
            && deletes = []
            && messages = []
            && not (Clock.Timer.has_expired timer)
          then (
            (* cur_id was bumped, but nothing relevent fell out of the database.
               Therefore the last ID the client got is equivalent to the current one. *)
            sub.cur_id <- last ;
            last_msg_gen := msg_gen ;
            wait2 sub last timer ;
            (* The next iteration will fold over events starting after
               the last database event that matched a subscription. *)
            let next = last in
            (self [@tailcall]) next
          ) else
            result
        in
        grab_nonempty_range from
    )
  in
  let {creates; mods; deletes; last} = events in
  let event_of op ?snapshot {table; obj; time} =
    {
      id= Int64.to_string time
    ; ts= "0.0"
    ; ty= String.lowercase_ascii table
    ; op
    ; reference= obj
    ; snapshot
    }
  in
  let events_of ~kind ?(with_snapshot = true) entries acc =
    let rec go events ({table; obj; time= _} as entry) =
      try
        let snapshot =
          let serialiser = Eventgen.find_get_record table in
          if with_snapshot then
            serialiser ~__context ~self:obj ()
          else
            None
        in
        let event = event_of kind ?snapshot entry in
        if Subscription.event_matches subs event then
          event :: events
        else
          events
      with _ ->
        (* CA-91931: An exception may be raised here if an object's
           lifetime is too short.

           The problem is that "collect_events" and "events_of" work
           on different versions of the database, so some `add and
           `mod events can be lost if the corresponding object is
           deleted before a snapshot is taken.

           In practice, this has only been seen with the "task"
           object - which can be rapidly created and destroyed using
           helper functions.

           These exceptions have been suppressed since [bc0cc5a9]. *)
        events
    in
    List.fold_left go acc entries
  in
  let events =
    [] (* Accumulate the events for objects stored in the database. *)
    |> events_of ~kind:`del ~with_snapshot:false deletes
    |> events_of ~kind:`_mod mods
    |> events_of ~kind:`add creates
  in
  let events =
    (* Messages require a special casing as their contents are not
       stored in the database. *)
    List.fold_left
      (fun acc mev ->
        let event =
          let table = "message" in
          match mev with
          | Message.Create (_ref, message) ->
              event_of `add
                ?snapshot:(Some (API.rpc_of_message_t message))
                {table; obj= Ref.string_of _ref; time= 0L}
          | Message.Del _ref ->
              event_of `del {table; obj= Ref.string_of _ref; time= 0L}
        in
        event :: acc
      )
      events messages
  in
  let valid_ref_counts =
    Db_cache_types.TableSet.fold
      (fun tablename _ table acc ->
        ( String.lowercase_ascii tablename
        , Db_cache_types.Table.fold (fun _ _ _ acc -> Int32.add 1l acc) table 0l
        )
        :: acc
      )
      tableset []
  in
  {events; valid_ref_counts; token= Token.to_string (last, msg_gen)}

let from ~__context ~classes ~token ~timeout =
  let duration =
    timeout
    |> Clock.Timer.s_to_span
    |> Option.value ~default:Mtime.Span.(24 * hour)
  in
  let timer = Clock.Timer.start ~duration in
  let subs = List.map Subscription.of_string classes in
  let batching =
    if List.for_all Subscription.is_task_only subs then
      !Xapi_globs.event_from_task_delay
    else
      !Xapi_globs.event_from_delay
  in
  let session = Context.get_session_id __context in
  let from, from_t =
    try Token.of_string token
    with e ->
      warn "Failed to parse event.from token: %s (%s)" token
        (Printexc.to_string e) ;
      raise
        (Api_errors.Server_error
           (Api_errors.event_from_token_parse_failure, [token])
        )
  in
  (* We need to iterate because it's possible for an empty event set
     	   to be generated if we peek in-between a Modify and a Delete; we'll
     	   miss the Delete event and fail to generate the Modify because the
     	   snapshot can't be taken. *)
  let rec loop () =
    let event_from =
      from_inner __context session subs from from_t timer batching
    in
    if event_from.events = [] && not (Clock.Timer.has_expired timer) then (
      debug "suppressing empty event.from" ;
      loop ()
    ) else
      rpc_of_event_from event_from
  in
  loop ()

let get_current_id ~__context = with_lock Next.m (fun () -> !Next.id)

let inject ~__context ~_class ~_ref =
  let open Xapi_database in
  let open Xapi_database.Db_cache_types in
  let generation : int64 =
    Db_lock.with_lock (fun () ->
        let db_ref = Db_backend.make () in
        let g =
          Manifest.generation (Database.manifest (Db_ref.get_database db_ref))
        in
        let ok =
          match Db_cache_impl.get_table_from_ref db_ref _ref with
          | Some tbl ->
              tbl = _class
          | None ->
              false
        in
        if not ok then
          raise
            (Api_errors.Server_error (Api_errors.handle_invalid, [_class; _ref])) ;
        Db_cache_impl.touch_row db_ref _class _ref ;
        (* consumes this generation *)
        g
    )
  in
  let token = (Int64.sub generation 1L, 0L) in
  Token.to_string token

(* Internal interface ****************************************************)

let generate_events_for =
  let table = Hashtbl.create 64 in
  let add_object ({name; gen_events; _} : Datamodel_types.obj) =
    (* Record only the names of objects that should generate events. *)
    if gen_events then
      Hashtbl.replace table name ()
  in
  Dm_api.objects_of_api Datamodel.all_api |> List.iter add_object ;
  Hashtbl.mem table

let event_add ?snapshot ty op reference =
  let add () =
    let id = Int64.to_string !Next.id in
    let ts = string_of_float (Unix.time ()) in
    let ty = String.lowercase_ascii ty in
    let op = op_of_string op in
    let ev = {id; ts; ty; op; reference; snapshot} in
    From.add ev ; Next.add ev
  in
  if generate_events_for ty then
    add ()

let register_hooks () = Xapi_database.Db_action_helper.events_register event_add

(* Called whenever a session is being destroyed i.e. by Session.logout and db_gc *)
let on_session_deleted session_id =
  (* Unregister this session if is associated with in imported DB. *)
  (* FIXME: this doesn't logically belong in the event code *)
  Xapi_database.Db_backend.unregister_session (Ref.string_of session_id) ;
  Next.on_session_deleted session_id ;
  From.on_session_deleted session_id

(* Inject an unnecessary update as a heartbeat. This will:
    1. hopefully prevent some firewalls from silently closing the connection
    2. allow the server to detect when a client has failed *)
let heartbeat ~__context =
  try
    Xapi_database.Db_lock.with_lock (fun () ->
        (* We must hold the database lock since we are sending an update for a real object
           			   and we don't want to accidentally transmit an older snapshot. *)
        let pool = try Some (Helpers.get_pool ~__context) with _ -> None in
        match pool with
        | Some pool ->
            let pool_r = Db.Pool.get_record ~__context ~self:pool in
            let pool_xml = API.rpc_of_pool_t pool_r in
            event_add ~snapshot:pool_xml "pool" "mod" (Ref.string_of pool)
        | None ->
            ()
        (* no pool object created during initial boot *)
    )
  with e ->
    error "Caught exception sending event heartbeat: %s"
      (ExnHelper.string_of_exn e)

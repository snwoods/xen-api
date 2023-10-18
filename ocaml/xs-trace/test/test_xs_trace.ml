let _ =
  let read_body ic file len =
    let line = really_input_string ic !len in
    Printf.fprintf file "%s\n" line
  in
  let len = ref 0 in
  let rec read_header ic file =
    match input_line ic with
    | line when line = "\r" ->
        read_body ic file len
    | line ->
        if String.starts_with ~prefix:"Content-Length: " line then
          (*Subtract one more than the length of Content-Length: so we don't read the trailing \r*)
          len := int_of_string (String.sub line 16 (String.length line - 17)) ;
        read_header ic file
    | exception End_of_file ->
        ()
  in
  let sock = Unix.socket Unix.PF_UNIX SOCK_STREAM 0 in
  Unix.bind sock (Unix.ADDR_UNIX "test-socket") ;
  Unix.listen sock 1 ;
  while true do
    let accept, _ = Unix.accept sock in
    let ic = Unix.in_channel_of_descr accept in
    let file =
      open_out_gen
        [Open_wronly; Open_append; Open_creat]
        0o600 "test-http-server.out"
    in
    read_header ic file ; close_out file ; Unix.close accept
  done

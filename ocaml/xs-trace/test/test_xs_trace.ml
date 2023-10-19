let _ =
  let inet_addr = Unix.ADDR_INET (Unix.inet_addr_of_string "127.0.0.1", 9411) in
  let read_body ic file len =
    let line = really_input_string ic len in
    Printf.fprintf file "%s\n" line
  in
  let rec read_header ic file len =
    match input_line ic with
    | "\r" ->
        read_body ic file len
    | line ->
        if String.starts_with ~prefix:"Content-Length: " line then
          (*Subtract one more than the length of Content-Length: so we don't read the trailing \r*)
          read_header ic file (int_of_string (String.sub line 16 (String.length line - 17)))
        else
          read_header ic file len
    | exception End_of_file ->
        ()
  in
  Unix.establish_server
    (fun ic _ ->
      let file =
        open_out_gen
          [Open_wronly; Open_append; Open_creat]
          0o600 "test-http-server.out"
      in
      read_header ic file 0 ; close_out file
    )
    inet_addr

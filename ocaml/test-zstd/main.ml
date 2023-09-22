let write_to ~file_path fd =
  Printf.printf "Beginning %!" ;
  Xapi_stdext_unix.Unixext.atomic_write_to_file (file_path ^ ".zstd") 0o444 (fun fd_2 ->
    let chunk = 4096 in
    let cache = Bytes.make chunk '\000' in
    let finished = ref false in
    while not !finished do
      let to_read = chunk in
      let read_bytes = Unix.read fd cache 0 to_read in
      let _ = Xapi_stdext_unix.Unixext.really_write fd_2 (Bytes.unsafe_to_string cache) 0 read_bytes in
      if read_bytes = 0 then finished := true
    done
  )

let compress_file file_path =
  let fd_r = Unix.openfile file_path [O_RDONLY] 0o000 in
  Zstd.Default.compress fd_r (write_to ~file_path)

let () = compress_file "/home/stevenwo/repos/newest/xen-api/ocaml/pg71692.txt"
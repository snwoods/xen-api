let write_to ~file_path fd_w =
  Printf.printf "Beginning %!" ;
  let fd_r = Unix.openfile file_path [O_RDONLY] 0o000 in
  let chunk = 4096 in
  let cache = Bytes.make chunk '\000' in
  let finished = ref false in
  while not !finished do
    let to_read = chunk in
    let read_bytes = Unix.read fd_r cache 0 to_read in
    let _ = Xapi_stdext_unix.Unixext.really_write fd_w (Bytes.unsafe_to_string cache) 0 read_bytes in
    if read_bytes = 0 then finished := true
  done

let compress_file file_path =
  let fd = Unix.openfile (file_path ^ ".zstd") [O_WRONLY] 0o444 in
  Zstd.Default.compress fd (write_to ~file_path)

let () = compress_file "/home/stevenwo/repos/newest/xen-api/ocaml/pg71692.txt"
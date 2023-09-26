let write_to ~file_path fd_w =
  Xapi_stdext_unix.Unixext.with_file file_path [O_RDONLY] 0o000 (fun fd_r ->
    Xapi_stdext_unix.Unixext.copy_file fd_r fd_w
    )

let compress_file file_path =
  Xapi_stdext_unix.Unixext.with_file (file_path ^ ".zstd") [O_WRONLY; O_CREAT] 0o444
    Zstd.Fast.compress (write_to ~file_path)

let () = ignore @@ compress_file "/home/stevenwo/repos/newest/xen-api/ocaml/pg71692.txt"
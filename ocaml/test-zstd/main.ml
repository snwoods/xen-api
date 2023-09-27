let write_to ~file_path fd_w =
  ignore @@ Xapi_stdext_unix.Unixext.with_file file_path [O_RDONLY] 0o000 (fun fd_r ->
    Xapi_stdext_unix.Unixext.copy_file fd_r fd_w) ;
  Unix.unlink file_path

let compress_file file_path =
  Xapi_stdext_unix.Unixext.with_file (file_path ^ ".zst") [O_WRONLY; O_CREAT] 0o444
    @@ fun zst_file -> Zstd.Fast.compress zst_file (write_to ~file_path)

let () =
  Debug.log_to_stdout () ;
  ignore @@ compress_file "/root/pg71692.txt"
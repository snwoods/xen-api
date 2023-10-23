(*
 * Copyright (C) 2023 Cloud Software Group
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

let _ =
  if Array.length Sys.argv <> 4 then (
    Printf.eprintf "Usage: %s cp/mv <origin> <destination>\n" Sys.argv.(0) ;
    exit 1
  ) ;
  let action = Sys.argv.(1) in
  let origin = Sys.argv.(2) in
  let url = Uri.of_string Sys.argv.(3) in
  let submit_json json =
    if json <> "" then
      let result = Tracing.Export.Destination.Http.export ~url json in
      match result with
      | Ok _ ->
          ()
      | Error err ->
          Printf.eprintf "Error: %s" (Printexc.to_string err) ;
          exit 1
  in
  let rec export_file orig =
    if Sys.is_directory orig then
      let files = Sys.readdir orig in
      let file_paths = Array.map (Filename.concat orig) files in
      Array.iter export_file file_paths
    else if Filename.check_suffix orig ".zst" then
      Xapi_stdext_unix.Unixext.with_file orig [O_RDONLY] 0o000
      @@ fun compressed_file ->
      Zstd.Fast.decompress_passive compressed_file @@ fun decompressed ->
      let ic = Unix.in_channel_of_descr decompressed in
      try
        while true do
          let line = input_line ic in
          submit_json line
        done
      with End_of_file -> ()
    else if Filename.check_suffix orig ".ndjson" then
      Xapi_stdext_unix.Unixext.readfile_line (fun line -> submit_json line) orig
    else
      let json = Xapi_stdext_unix.Unixext.string_of_file orig in
      submit_json json
  in
  export_file origin ;
  let rec remove_all orig =
    if Sys.is_directory orig then (
      let files = Sys.readdir orig in
      let file_paths = Array.map (Filename.concat orig) files in
      Array.iter remove_all file_paths ;
      Sys.rmdir orig
    ) else
      Sys.remove orig
  in
  if action = "mv" then
    remove_all origin

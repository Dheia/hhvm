(*
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 *)

open Hh_prelude
open Sys_utils

type t = string SMap.t

let file_path_relative_to_repo_root = ".hhconfig"

(* c.f. [ConfigFile::empty] in Rust *)
let empty () = SMap.empty

(* c.f. [ConfigFile::print_to_stderr] in Rust *)
let print_config (config : t) : unit =
  SMap.iter (fun k v -> Printf.eprintf "%s = %s\n" k v) config

(* c.f. [ConfigFile::apply_overrides] in Rust *)
let apply_overrides ~silent ~(config : t) ~(overrides : t) : t =
  if SMap.cardinal overrides = 0 then
    config
  else
    (* Note that the order of arguments matters because SMap.union is left-biased by default. *)
    let config = SMap.union overrides config in
    if not silent then (
      Printf.eprintf "Config overrides:\n";
      print_config overrides;
      Printf.eprintf "\nThe combined config:\n";
      print_config config
    );
    config

(*
 * Config file format:
 * # Some comment. Indicate by a pound sign at the start of a new line
 * key = a possibly space-separated value
 *
 * c.f. [ConfigFile::from_slice] in Rust
 *)
let parse_contents (contents : string) : t =
  let lines = Str.split (Str.regexp "\n") contents in
  List.fold_left
    lines
    ~f:
      begin
        fun acc line ->
        if
          String.(strip line = "")
          || (String.length line > 0 && Char.equal line.[0] '#')
        then
          acc
        else
          let parts = Str.bounded_split (Str.regexp "=") line 2 in
          match parts with
          | [k; v] -> SMap.add (String.strip k) (String.strip v) acc
          | [k] -> SMap.add (String.strip k) "" acc
          | _ -> failwith "failed to parse config"
      end
    ~init:SMap.empty

(* c.f. [ConfigFile::from_file_with_sha1] in Rust *)
let parse ~silent (fn : string) : string * t =
  let contents = cat fn in
  if not silent then
    Printf.eprintf "%s on-file-system contents:\n%s\n" fn contents;
  let parsed = parse_contents contents in
  let hash = Sha1.digest contents in
  (hash, parsed)

let parse_local_config ~silent (fn : string) : t =
  try
    let (_hash, config) = parse ~silent fn in
    config
  with
  | e ->
    Hh_logger.log "Loading config exception: %s" (Exn.to_string e);
    Hh_logger.log "Could not load config at %s" fn;
    SMap.empty

(* c.f. [ConfigFile::to_json] in Rust *)
let to_json t = Hh_json.JSON_Object (SMap.elements @@ SMap.map Hh_json.string_ t)

(* c.f. [impl FromIterator<(String, String)> for ConfigFile] in Rust *)
let of_list = SMap.of_list

(* c.f. [ConfigFile::keys] in Rust *)
let keys = SMap.keys

module Getters = struct
  let string_opt key config = SMap.find_opt key config

  let string_ key ~default config =
    Option.value (SMap.find_opt key config) ~default

  let int_ key ~default config =
    Option.value_map (SMap.find_opt key config) ~default ~f:int_of_string

  let int_opt key config =
    Option.map (SMap.find_opt key config) ~f:int_of_string

  let float_ key ~default config =
    Option.value_map (SMap.find_opt key config) ~default ~f:float_of_string

  let float_opt key config =
    Option.map (SMap.find_opt key config) ~f:float_of_string

  let bool_ key ~default config =
    Option.value_map (SMap.find_opt key config) ~default ~f:bool_of_string

  let bool_opt key config =
    Option.map (SMap.find_opt key config) ~f:bool_of_string

  let string_list_opt key config =
    SMap.find_opt key config
    |> Option.map ~f:(Str.split (Str.regexp ",[ \n\r\x0c\t]*"))

  let string_list ~delim key ~default config =
    Option.value_map (SMap.find_opt key config) ~default ~f:(Str.split delim)

  let bool_if_min_version key ~default ~current_version config : bool =
    let version_value = string_ key ~default:(string_of_bool default) config in
    match version_value with
    | "true" -> true
    | "false" -> false
    | version_value ->
      let version_value =
        Config_file_version.parse_version (Some version_value)
      in
      if Config_file_version.compare_versions current_version version_value >= 0
      then
        true
      else
        false
end

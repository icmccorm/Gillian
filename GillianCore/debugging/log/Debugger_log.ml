module L = Logging

let file_name = "./gillian-debugger.log"
let rpc_ref : Debug_rpc.t option ref = ref None

module JsonMap = struct
  type t = (string * Yojson.Safe.t) list

  let to_yojson jsonMap : Yojson.Safe.t = `Assoc jsonMap

  let of_yojson (yojson : Yojson.Safe.t) =
    match yojson with
    | `Assoc jsonMap -> Ok jsonMap
    | _ -> Error "Invalid yojson for jsonMap"
end

let get_fmt_with_json msgf : string * JsonMap.t =
  let result = ref ("", []) in
  (fun ?(json : JsonMap.t = []) fmt ->
    Format.kasprintf (fun s -> result := (s, json)) fmt)
  |> msgf;
  !result

exception FailureJson of string * JsonMap.t

let info line =
  let out = open_out_gen [ Open_append; Open_creat ] 0o666 file_name in
  Printf.fprintf out "%s\n" line;
  close_out out

let enabled () = Option.is_some !rpc_ref
let reset () = if Sys.file_exists file_name then Sys.remove file_name else ()

let setup rpc =
  reset ();
  rpc_ref := Some rpc

module Log_event = struct
  let type_ = "log"

  module Payload = struct
    type t = { msg : string; json : JsonMap.t }
    [@@deriving yojson { strict = false }]
  end
end

let to_rpc msg json =
  match !rpc_ref with
  | Some rpc ->
      (info
         (match json with
         | _ :: _ -> msg ^ " (+)"
         | [] -> msg);
       Debug_rpc.send_event rpc (module Log_event) { msg; json })
      |> ignore
  | None -> ()

let log f =
  if enabled () then
    let msg, json = get_fmt_with_json f in
    to_rpc msg json

let show_report id msg =
  log (fun m ->
      let report_json : Yojson.Safe.t =
        match L.LogQueryer.get_report id with
        | Some (content, type_) ->
            `Assoc
              [
                ("content", Yojson.Safe.from_string content);
                ("type", `String type_);
              ]
        | None -> `Null
      in
      m ~json:[ ("report", report_json) ] "%s" msg)

let failwith json_f msg =
  if enabled () then
    let json = json_f () in
    raise @@ FailureJson (msg, json)
  else failwith msg
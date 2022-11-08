module L = Logging
module DL = Debugger_log
open Lifter

type rid = L.ReportId.t [@@deriving yojson, show]

module Make
    (PC : ParserAndCompiler.S)
    (Verifier : Verifier.S with type annot = PC.Annot.t)
    (SMemory : SMemory.S) :
  S
    with type memory = SMemory.t
     and type tl_ast = PC.tl_ast
     and type memory_error = SMemory.err_t
     and type cmd_report = Verifier.SAInterpreter.Logging.ConfigReport.t
     and type annot = PC.Annot.t = struct
  open ExecMap
  module Annot = PC.Annot

  type annot = PC.Annot.t
  type branch_case = BranchCase.t [@@deriving yojson]
  type branch_path = BranchCase.path [@@deriving yojson]

  (* Some fields are Null'd in yojson to stop huge memory inefficiency *)
  type map = (branch_case, cmd_data, unit) ExecMap.t

  and cmd_data = {
    id : rid;
    display : string;
    unifys : unifys;
    errors : string list;
    submap : map submap;
    branch_path : branch_path;
    parent : (map * branch_case option) option; [@to_yojson fun _ -> `Null]
  }
  [@@deriving to_yojson]

  type t = {
    map : map;
    root_proc : string;
    id_map : (rid, map) Hashtbl.t; [@to_yojson fun _ -> `Null]
  }
  [@@deriving to_yojson]

  type memory = SMemory.t
  type tl_ast = PC.tl_ast
  type memory_error = SMemory.err_t

  type cmd_report = Verifier.SAInterpreter.Logging.ConfigReport.t
  [@@deriving yojson]

  type exec_data = cmd_report executed_cmd_data [@@deriving yojson]

  let dump = to_yojson

  let get_proc_name ({ cmd_report; _ } : exec_data) =
    let open Verifier.SAInterpreter.Logging.ConfigReport in
    let cs = cmd_report.callstack in
    let head = List.hd cs in
    head.pid

  let new_cmd
      ?(submap = NoSubmap)
      ~parent
      id_map
      { kind; id; unifys; errors; cmd_report : cmd_report; branch_path }
      () =
    let display = Fmt.to_to_string Cmd.pp_indexed cmd_report.cmd in
    let data = { id; display; unifys; errors; submap; branch_path; parent } in
    let cmd =
      match kind with
      | Normal -> Cmd { data; next = Nothing }
      | Branch cases ->
          let nexts = Hashtbl.create (List.length cases) in
          cases
          |> List.iter (fun (case, _) -> Hashtbl.add nexts case ((), Nothing));
          BranchCmd { data; nexts }
      | Final -> FinalCmd { data }
    in
    Hashtbl.replace id_map id cmd;
    cmd

  let get_id_opt = function
    | Nothing -> None
    | Cmd { data; _ } | BranchCmd { data; _ } | FinalCmd { data; _ } ->
        Some data.id

  let get_id map =
    match get_id_opt map with
    | None -> failwith "Tried to get id of Nothing!"
    | Some id -> id

  let at_id_result id state =
    match Hashtbl.find_opt state.id_map id with
    | None -> Error "id not found"
    | Some Nothing -> Error "HORROR - got Nothing at id!"
    | Some
        ((Cmd { data; _ } | BranchCmd { data; _ } | FinalCmd { data }) as map)
      -> Ok (map, data.branch_path)

  let at_id_opt id state =
    match at_id_result id state with
    | Ok (map, branch_path) -> Some (map, branch_path)
    | Error _ -> None

  let at_id id state =
    match at_id_result id state with
    | Ok (map, branch_path) -> (map, branch_path)
    | Error s ->
        DL.failwith
          (fun () -> [ ("id", rid_to_yojson id); ("state", dump state) ])
          ("at_id: " ^ s)

  let init _ _ exec_data =
    let id_map = Hashtbl.create 1 in
    let map = new_cmd id_map exec_data ~parent:None () in
    let root_proc = get_proc_name exec_data in
    ({ map; root_proc; id_map }, Stop)

  let init_opt _ _ exec_data = Some (init "" None exec_data)

  let handle_cmd prev_id branch_case exec_data state =
    let { root_proc; id_map; _ } = state in
    let new_cmd = new_cmd id_map exec_data in
    let failwith s =
      DL.failwith
        (fun () ->
          [
            ("state", dump state);
            ("exec_data", exec_data_to_yojson exec_data);
            ("prev_id", rid_to_yojson prev_id);
            ("branch_case", opt_to_yojson branch_case_to_yojson branch_case);
          ])
        ("handle_cmd: " ^ s)
    in
    let map =
      match Hashtbl.find_opt id_map prev_id with
      | Some map -> map
      | None -> failwith (Fmt.str "couldn't find prev_id %a!" pp_rid prev_id)
    in
    (match map with
    | Cmd cmd when cmd.next = Nothing ->
        let parent = Some (map, None) in
        cmd.next <- new_cmd ~parent ()
    | Cmd _ -> failwith "cmd.next not Nothing!"
    | BranchCmd { nexts; _ } -> (
        match branch_case with
        | None -> failwith "HORROR - need branch case to insert to branch cmd!"
        | Some case -> (
            match Hashtbl.find_opt nexts case with
            | Some ((), Nothing) ->
                let parent = Some (map, Some case) in
                Hashtbl.replace nexts case ((), new_cmd ~parent ())
            | _ -> failwith "colliding cases in branch cmd"))
    | _ -> failwith "can't insert to Nothing or FinalCmd");
    let { id; cmd_report; _ } = exec_data in
    let current_proc = get_proc_name exec_data in
    if root_proc <> current_proc || Annot.is_hidden cmd_report.annot then
      ExecNext (Some id, None)
    else Stop

  let package_case _ = Packaged.package_case

  let package_data package { id; display; unifys; errors; submap; _ } =
    let submap =
      match submap with
      | NoSubmap -> NoSubmap
      | Proc p -> Proc p
      | Submap map -> Submap (package map)
    in
    Packaged.{ ids = [ id ]; display; unifys; errors; submap }

  let package = Packaged.package package_data package_case
  let get_gil_map state = package state.map
  let get_lifted_map_opt _ = None

  let get_lifted_map _ =
    failwith "get_lifted_map not implemented for GIL lifter"

  let get_unifys_at_id id state =
    match state |> at_id id |> fst with
    | Nothing ->
        DL.failwith
          (fun () -> [ ("id", rid_to_yojson id); ("state", dump state) ])
          "get_unifys_at_id: HORROR - map is Nothing!"
    | Cmd { data; _ } | BranchCmd { data; _ } | FinalCmd { data } -> data.unifys

  let get_root_id { map; _ } =
    match map with
    | Nothing -> None
    | Cmd { data; _ } | BranchCmd { data; _ } | FinalCmd { data } ->
        Some data.id

  let path_of_id id state = state |> at_id id |> snd

  let existing_next_steps id state =
    match state |> at_id_opt id with
    | None -> []
    | Some (map, _) -> (
        match map with
        | Nothing -> failwith "existing_next_steps: map is Nothing!"
        | Cmd { next = Nothing; _ } | FinalCmd _ -> []
        | Cmd { next; _ } ->
            let id = get_id next in
            [ (id, None) ]
        | BranchCmd { nexts; _ } ->
            let nexts =
              Hashtbl.fold
                (fun case (_, next) acc ->
                  match get_id_opt next with
                  | None -> acc
                  | Some id -> (id, Some case) :: acc)
                nexts []
            in
            List.rev nexts)

  let next_step_specific id case _ =
    let case =
      case
      |> Option.map (fun (case : ExecMap.Packaged.branch_case) ->
             case.json |> BranchCase.of_yojson |> Result.get_ok)
    in
    (id, case)

  let previous_step id state =
    match state |> at_id id |> fst with
    | Nothing -> failwith "HORROR - map is Nothing!"
    | Cmd { data; _ } | BranchCmd { data; _ } | FinalCmd { data } -> (
        match data.parent with
        | None -> None
        | Some (Nothing, _) -> failwith "HORROR - parent is Nothing!"
        | Some
            ((Cmd { data; _ } | BranchCmd { data; _ } | FinalCmd { data }), case)
          ->
            let case = case |> Option.map ExecMap.Packaged.package_case in
            Some (data.id, case))

  let select_next_path case id state =
    let map, path = state |> at_id id in
    let failwith s =
      DL.failwith
        (fun () ->
          [
            ("id", rid_to_yojson id);
            ("state", dump state);
            ("case", opt_to_yojson branch_case_to_yojson case);
          ])
        ("select_next_path: " ^ s)
    in
    match (map, case) with
    | (Nothing | FinalCmd _), _ -> failwith "no next path"
    | Cmd _, Some _ -> failwith "tried to select case for non-branch cmd"
    | Cmd _, None -> path
    | BranchCmd { nexts; _ }, None ->
        Hashtbl.find_map (fun case _ -> Some (case :: path)) nexts |> Option.get
    | BranchCmd { nexts; _ }, Some case -> (
        match Hashtbl.find_opt nexts case with
        | None -> failwith "case not found"
        | Some _ -> case :: path)

  let find_unfinished_path ?at_id state =
    let rec aux = function
      | Nothing ->
          DL.failwith
            (fun () ->
              [
                ("state", dump state);
                ("at_id", opt_to_yojson rid_to_yojson at_id);
              ])
            "find_unfinished_path: started at Nothing"
      | Cmd { data = { id; _ }; next = Nothing } -> Some (id, None)
      | Cmd { next; _ } -> aux next
      | BranchCmd { nexts; data = { id; _ } } -> (
          match
            Hashtbl.find_map
              (fun case (_, next) ->
                if next = Nothing then Some (id, Some case) else None)
              nexts
          with
          | None -> Hashtbl.find_map (fun _ (_, next) -> aux next) nexts
          | result -> result)
      | FinalCmd _ -> None
    in
    let map =
      match at_id with
      | None -> state.map
      | Some id -> Hashtbl.find state.id_map id
    in
    aux map

  let memory_error_to_exception_info { error; _ } : exception_info =
    { id = Fmt.to_to_string SMemory.pp_err error; description = None }

  let add_variables ~store ~memory ~is_gil_file ~get_new_scope_id variables :
      scope list =
    let () = ignore is_gil_file in
    let store_id = get_new_scope_id () in
    let memory_id = get_new_scope_id () in
    let scopes : scope list =
      [ { id = store_id; name = "Store" }; { id = memory_id; name = "Memory" } ]
    in
    let store_vars =
      store
      |> List.map (fun (var, value) : variable ->
             let value = Fmt.to_to_string (Fmt.hbox Expr.pp) value in
             create_leaf_variable var value ())
      |> List.sort (fun (v : variable) w -> Stdlib.compare v.name w.name)
    in
    let memory_vars =
      [
        create_leaf_variable ""
          (Fmt.to_to_string (Fmt.hbox SMemory.pp) memory)
          ();
      ]
    in
    let () = Hashtbl.replace variables store_id store_vars in
    let () = Hashtbl.replace variables memory_id memory_vars in
    scopes
end
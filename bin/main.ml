open Fortscript

let usage = "Usage: fortscript <input.py> [-o output.f90]"

module StringSet = Set.Make(String)

let ensure_trailing_newline content =
  if String.length content > 0 && content.[String.length content - 1] <> '\n' then
    content ^ "\n"
  else
    content

let absolute_path path =
  if Filename.is_relative path then
    Filename.concat (Sys.getcwd ()) path
  else
    path

let parse_program input_file =
  let ic = open_in input_file in
  let content = In_channel.input_all ic in
  close_in ic;
  let content = ensure_trailing_newline content in
  let lexbuf = Lexing.from_string content in
  Lexing.set_filename lexbuf input_file;
  Lexer.reset_lexer ();
  let first_token = ref true in
  let token lexbuf =
    if !first_token then begin
      first_token := false;
      Lexer.init_and_token lexbuf
    end else
      Lexer.token lexbuf
  in
  try Parser.program token lexbuf
  with
  | Parser.Error ->
    let pos = lexbuf.lex_curr_p in
    Printf.eprintf "Parse error at %s:%d:%d\n"
      pos.pos_fname pos.pos_lnum (pos.pos_cnum - pos.pos_bol);
    exit 1
  | Lexer.LexError msg ->
    Printf.eprintf "Lexer error: %s\n" msg;
    exit 1

let resolve_import_path importer module_name =
  let importer_dir = Filename.dirname importer in
  let relative_path = absolute_path (Filename.concat importer_dir (module_name ^ ".py")) in
  if Sys.file_exists relative_path then
    relative_path
  else
    absolute_path (module_name ^ ".py")  (* Allow support/... imports from the repo root. *)

let rec load_program visited input_file =
  let normalized = absolute_path input_file in
  if StringSet.mem normalized !visited then
    []
  else if not (Sys.file_exists normalized) then
    failwith (Printf.sprintf "Import not found: %s" normalized)
  else begin
    visited := StringSet.add normalized !visited;
    let parsed = parse_program normalized in
    let rec expand acc = function
      | [] -> List.rev acc
      | Ast.Import module_name :: rest ->
        let imported_file = resolve_import_path normalized module_name in
        let imported_program = load_program visited imported_file in
        (* Imported declarations are spliced in place once. *)
        expand (List.rev_append imported_program acc) rest
      | decl :: rest ->
        expand (decl :: acc) rest
    in
    expand [] parsed
  end

let () =
  let input_file = ref "" in
  let output_file = ref "" in
  let args = [
    ("-o", Arg.Set_string output_file, "Output file (default: stdout)");
  ] in
  Arg.parse args (fun f -> input_file := f) usage;

  if !input_file = "" then begin
    Printf.eprintf "%s\n" usage;
    exit 1
  end;

  let program =
    let visited = ref StringSet.empty in
    try load_program visited !input_file
    with Failure msg ->
      Printf.eprintf "Import error: %s\n" msg;
      exit 1
  in

  (* Semantic checks *)
  (try Semantic.check program
   with Semantic.SemanticError msg ->
     Printf.eprintf "%s\n" msg;
     exit 1);

  (* Generate Fortran *)
  let fortran = Codegen.generate program in

  (* Output *)
  if !output_file <> "" then begin
    let oc = open_out !output_file in
    output_string oc fortran;
    close_out oc;
    Printf.printf "Generated: %s\n" !output_file
  end else
    print_string fortran

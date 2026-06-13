open Ast
open Codegen_state
open Codegen_analysis
open Codegen_types
open Codegen_stmt

(* Procedure-level codegen: local-decl collection, procedure preamble, body
   emission, GPU interface generation, and abstract-interface synthesis for
   callable parameter types. *)

(* ---- Collect local variable declarations from a statement list ---- *)
let rec collect_decls stmts =
  List.concat_map collect_decl_stmt stmts

and collect_decl_stmt = function
  | VarDecl (name, typ, _) -> [(name, typ)]
  | If { body; elifs; else_body; _ } ->
    collect_decls body @
    List.concat_map (fun (_, b) -> collect_decls b) elifs @
    collect_decls else_body
  | For { for_body; var; _ } ->
    (var, TInt) :: collect_decls for_body
  | While (_, body) -> collect_decls body
  | SyncAll | Allocate _ | Break -> []
  | _ -> []

(* Check if generated body uses the implicit loop variable *)
let body_uses_implicit_loop_var body_str =
  try ignore (Str.search_forward (Str.regexp_string "fortscript_i__") body_str 0); true
  with Not_found -> false

let initialize_proc_context (fd : func_def) =
  fstr_tmp_counter := 0;
  fstr_max_index := 0;
  fstr_prestmts := [];
  Hashtbl.clear coarray_vars;
  Hashtbl.clear current_callable_params;
  Hashtbl.clear current_var_types;
  Hashtbl.iter (fun name typ ->
    Hashtbl.replace current_var_types name typ
  ) global_var_types;
  Hashtbl.iter (fun name is_coarray ->
    Hashtbl.replace coarray_vars name is_coarray
  ) global_coarray_vars;
  List.iter (fun p ->
    match p.param_type with
    | TFunc _ -> Hashtbl.replace current_callable_params p.param_name p.param_type
    | TCoarray (_, extra) -> Hashtbl.replace coarray_vars p.param_name (List.length extra)
    | _ -> ()
  ) fd.params;
  List.iter (fun p ->
    Hashtbl.replace current_var_types p.param_name p.param_type
  ) fd.params

let emit_proc_signature ?(gpu_abi=false) buf indent (fd : func_def) =
  let ind = indent_str indent in
  let is_void = fd.return_type = TVoid in
  let is_pure = Hashtbl.mem pure_functions fd.func_name in
  let params_str =
    if gpu_abi then String.concat ", " (gpu_signature_names fd.params)
    else String.concat ", " (List.map (fun p -> p.param_name) fd.params)
  in
  let pure_prefix = if is_pure then "pure " else "" in
  if is_void then
    Buffer.add_string buf (Printf.sprintf "%s%ssubroutine %s(%s)\n"
      ind pure_prefix fd.func_name params_str)
  else
    Buffer.add_string buf (Printf.sprintf "%s%sfunction %s(%s) result(fortscript_result__)\n"
      ind pure_prefix fd.func_name params_str)

let emit_proc_body_lines buf indent (fd : func_def) body_str =
  let proc_ind = indent_str indent in
  let is_void = fd.return_type = TVoid in
  let lines = String.split_on_char '\n' body_str in
  List.iter (fun line ->
    if line = "" then ()
    else begin
      let trimmed = String.trim line in
      let return_prefix = "__RETURN__ " in
      let rp_len = String.length return_prefix in
      if String.length trimmed > rp_len && String.sub trimmed 0 rp_len = return_prefix then begin
        let value = String.sub trimmed rp_len (String.length trimmed - rp_len) in
        if not is_void then begin
          Buffer.add_string buf (Printf.sprintf "%s  fortscript_result__ = %s\n" proc_ind value);
          Buffer.add_string buf (Printf.sprintf "%s  return\n" proc_ind)
        end else
          Buffer.add_string buf (Printf.sprintf "%s  return\n" proc_ind)
      end else
        Buffer.add_string buf (line ^ "\n")
    end
  ) lines

let rec gen_procedure ?(indent = 1) ?(contained : func_def list = []) ?(gpu_abi=false) (fd : func_def) =
  if is_lapack_qr_stub fd || is_lapack_solve_stub fd || is_lapack_svd_stub fd || is_lapack_eig_stub fd ||
     is_random_fill_stub fd || is_uniform_fill_stub fd || is_random_seed_stub fd ||
     is_prand_uniform_stub fd || is_prand_uniform_thread_stub fd || is_prand_seed_parallel_stub fd ||
     is_geom_stl_read_ascii_stub fd || is_geom_stl_read_binary_stub fd then
    ""
  else
  let buf = Buffer.create 1024 in
  let is_void = fd.return_type = TVoid in
  let proc_ind = indent_str indent in
  let prev_proc_name = !current_proc_name in
  current_proc_name := Some fd.func_name;
  emit_proc_signature ~gpu_abi buf indent fd;
  Buffer.add_string buf (Printf.sprintf "%s  implicit none\n" proc_ind);

  initialize_proc_context fd;

  if gpu_abi then
    emit_gpu_param_decls buf proc_ind fd fd.params
  else
    List.iter (fun p ->
      match p.param_type with
      | TFunc _ ->
        Buffer.add_string buf (Printf.sprintf "%s  %s\n" proc_ind
          (fortran_type_decl p.param_name p.param_type))
      | _ ->
        let modified = param_is_modified p.param_name fd.body in
        let intent = if modified then "intent(inout)" else "intent(in)" in
        Buffer.add_string buf (Printf.sprintf "%s  %s\n" proc_ind
          (fortran_type_decl ~intent p.param_name p.param_type))
    ) fd.params;

  if not is_void then
    Buffer.add_string buf (Printf.sprintf "%s  %s\n" proc_ind
      (fortran_type_decl "fortscript_result__" fd.return_type));

  let locals = collect_decls fd.body in
  let seen = Hashtbl.create 16 in
  List.iter (fun (name, typ) ->
    (match typ with
     | TCoarray (_, extra) -> Hashtbl.replace coarray_vars name (List.length extra)
     | _ -> ());
    Hashtbl.replace current_var_types name typ;
    if not (Hashtbl.mem seen name) then begin
      Hashtbl.add seen name true;
      let is_param = List.exists (fun p -> p.param_name = name) fd.params in
      if not is_param then
        Buffer.add_string buf (Printf.sprintf "%s  %s\n" proc_ind
          (fortran_type_decl ~is_local:true name typ))
    end
  ) locals;

  let body_buf = Buffer.create 512 in
  gen_stmts_into body_buf (indent + 1) fd.body;
  let body_str = Buffer.contents body_buf in
  if body_uses_implicit_loop_var body_str then
    Buffer.add_string buf (Printf.sprintf "%s  integer :: fortscript_i__\n" proc_ind);
  if !fstr_max_index > 0 then begin
    let names = String.concat ", " (List.init !fstr_max_index (fun i ->
      Printf.sprintf "fortscript_fstr_tmp_%d__" (i + 1))) in
    Buffer.add_string buf (Printf.sprintf "%s  character(len=256) :: %s\n" proc_ind names)
  end;

  Buffer.add_string buf "\n";
  emit_proc_body_lines buf indent fd body_str;

  if is_void && fd.func_name = "main" && !coarrays_enabled then
    Buffer.add_string buf (Printf.sprintf "%s  sync all\n" proc_ind);

  if contained <> [] then begin
    Buffer.add_string buf (Printf.sprintf "%scontains\n\n" proc_ind);
    List.iter (fun (helper_fd : func_def) ->
      if List.exists stmt_contains_gpu helper_fd.body then
        failwith ("GPU helper function extraction does not support nested @gpu procedures: " ^ helper_fd.func_name);
      let helper_src = gen_procedure ~indent:(indent + 1) helper_fd in
      if helper_src <> "" then begin
        Buffer.add_string buf helper_src;
        Buffer.add_string buf "\n"
      end
    ) contained
  end;

  if is_void then
    Buffer.add_string buf (Printf.sprintf "%send subroutine %s\n" proc_ind fd.func_name)
  else
    Buffer.add_string buf (Printf.sprintf "%send function %s\n" proc_ind fd.func_name);
  current_proc_name := prev_proc_name;
  Buffer.contents buf

(* Wire up the forward reference so Codegen_stmt.gen_gpu_kernel_call can call
   back into gen_procedure for kernel emission. *)
let () = gen_procedure_ref := (fun indent contained gpu_abi fd ->
  gen_procedure ~indent ~contained ~gpu_abi fd)

let gen_gpu_interface kernel_name params body =
  let pseudo_fd = { func_name = kernel_name; params; return_type = TVoid; body } in
  let buf = Buffer.create 256 in
  Buffer.add_string buf "  interface\n";
  Buffer.add_string buf (Printf.sprintf "    subroutine %s(%s)\n"
    kernel_name (String.concat ", " (gpu_signature_names params)));
  Buffer.add_string buf "      implicit none\n";
  emit_gpu_param_decls buf "    " pseudo_fd params;
  Buffer.add_string buf (Printf.sprintf "    end subroutine %s\n" kernel_name);
  Buffer.add_string buf "  end interface\n";
  Buffer.contents buf

let collect_callable_types program =
  let seen = Hashtbl.create 16 in
  let ordered = ref [] in
  let rec note_type typ =
    match typ with
    | TFunc (param_types, return_type) ->
      let key = callable_type_key typ in
      if not (Hashtbl.mem seen key) then begin
        Hashtbl.add seen key true;
        ordered := typ :: !ordered
      end;
      List.iter note_type param_types;
      note_type return_type
    | TArray (elem_t, _) -> note_type elem_t
    | TCoarray (elem_t, _) -> note_type elem_t
    | _ -> ()
  in
  let note_param p =
    note_type p.param_type;
    (match p.default_value with
     | Some e -> ignore e
     | None -> ())
  in
  List.iter (function
    | Import _ -> ()
    | StructDef (_, fields) ->
      List.iter (fun field -> note_type field.field_type) fields
    | FuncDef fd ->
      List.iter note_param fd.params;
      note_type fd.return_type
    | GlobalVarDecl (_, typ, _) ->
      note_type typ
  ) program;
  List.rev !ordered

let gen_callable_interface typ =
  match typ with
  | TFunc (param_types, return_type) ->
    let iface_name = callable_interface_name typ in
    let buf = Buffer.create 256 in
    if return_type = TVoid then
      Buffer.add_string buf (Printf.sprintf "  abstract interface\n    subroutine %s(" iface_name)
    else
      Buffer.add_string buf (Printf.sprintf
        "  abstract interface\n    function %s(" iface_name);
    Buffer.add_string buf
      (String.concat ", " (List.mapi (fun idx _ -> Printf.sprintf "arg%d" (idx + 1)) param_types));
    if return_type = TVoid then
      Buffer.add_string buf ")\n"
    else
      Buffer.add_string buf ") result(fortscript_result__)\n";
    Buffer.add_string buf "      implicit none\n";
    List.iteri (fun idx param_type ->
      Buffer.add_string buf (Printf.sprintf
        "      %s\n"
        (fortran_type_decl ~intent:"intent(in)" (Printf.sprintf "arg%d" (idx + 1)) param_type))
    ) param_types;
    if return_type <> TVoid then
      Buffer.add_string buf (Printf.sprintf
        "      %s\n" (fortran_type_decl "fortscript_result__" return_type));
    if return_type = TVoid then
      Buffer.add_string buf (Printf.sprintf "    end subroutine %s\n  end interface\n" iface_name)
    else
      Buffer.add_string buf (Printf.sprintf "    end function %s\n  end interface\n" iface_name);
    Buffer.contents buf
  | _ -> failwith "Expected callable type"

open Ast
open Codegen_state

(* Program-walking analyses: call/reference collection, reachability, purity,
   variable scanning, GPU kernel parameter extraction. *)

(* Collect all function calls within statements *)
let rec collect_calls_stmts stmts =
  List.concat_map collect_calls_stmt stmts

and collect_calls_stmt = function
  | Assign (_, e) | ExprStmt e -> collect_calls_expr e
  | VarDecl (_, _, Some e) -> collect_calls_expr e
  | VarDecl (_, _, None) -> []
  | AugAssign (_, _, e) -> collect_calls_expr e
  | Return (Some e) -> collect_calls_expr e
  | Return None -> []
  | Break -> []
  | If { cond; body; elifs; else_body } ->
    collect_calls_expr cond @
    collect_calls_stmts body @
    List.concat_map (fun (c, b) -> collect_calls_expr c @ collect_calls_stmts b) elifs @
    collect_calls_stmts else_body
  | For { start_expr; end_expr; step_expr; for_body; _ } ->
    collect_calls_expr start_expr @
    collect_calls_expr end_expr @
    (match step_expr with Some e -> collect_calls_expr e | None -> []) @
    collect_calls_stmts for_body
  | While (cond, body) -> collect_calls_expr cond @ collect_calls_stmts body
  | Print args -> List.concat_map collect_calls_expr args
  | SyncAll -> []
  | Allocate (_, dims) -> List.concat_map collect_calls_expr dims
  | Pass -> []

and collect_calls_expr = function
  | Call (name, args) -> name :: List.concat_map collect_calls_expr args
  | BinOp (_, l, r) -> collect_calls_expr l @ collect_calls_expr r
  | UnaryOp (_, e) -> collect_calls_expr e
  | Index (e, subs) -> collect_calls_expr e @ List.concat_map collect_calls_subscript subs
  | CoarrayIndex (e, idxs) -> collect_calls_expr e @ List.concat_map collect_calls_expr idxs
  | FieldAccess (e, _) -> collect_calls_expr e
  | ArrayLit elems -> List.concat_map collect_calls_expr elems
  | FString parts -> List.concat_map (fun p -> match p with FStrExpr (e, _) -> collect_calls_expr e | FStrLit _ -> []) parts
  | _ -> []

and collect_calls_subscript = function
  | IndexSubscript e -> collect_calls_expr e
  | SliceSubscript (start_e, stop_e, step_e) ->
    (* Slice bounds can themselves call functions. *)
    let calls = match start_e with Some e -> collect_calls_expr e | None -> [] in
    let calls = match stop_e with Some e -> calls @ collect_calls_expr e | None -> calls in
    (match step_e with Some e -> calls @ collect_calls_expr e | None -> calls)

let collect_calls_global_init = function
  | GlobalVarDecl (_, _, Some e) -> collect_calls_expr e
  | GlobalVarDecl (_, _, None) | FuncDef _ | StructDef _ | Import _ -> []

let rec collect_function_refs_stmts funcs stmts =
  List.concat_map (collect_function_refs_stmt funcs) stmts

and collect_function_refs_stmt funcs = function
  | Assign (target, value) ->
    collect_function_refs_expr funcs target @ collect_function_refs_expr funcs value
  | ExprStmt e | VarDecl (_, _, Some e) | AugAssign (_, _, e) | Return (Some e) ->
    collect_function_refs_expr funcs e
  | VarDecl (_, _, None) | Return None | Break | SyncAll | Pass -> []
  | If { cond; body; elifs; else_body } ->
    collect_function_refs_expr funcs cond @
    collect_function_refs_stmts funcs body @
    List.concat_map (fun (c, b) ->
      collect_function_refs_expr funcs c @ collect_function_refs_stmts funcs b
    ) elifs @
    collect_function_refs_stmts funcs else_body
  | For { start_expr; end_expr; step_expr; for_body; _ } ->
    collect_function_refs_expr funcs start_expr @
    collect_function_refs_expr funcs end_expr @
    (match step_expr with Some e -> collect_function_refs_expr funcs e | None -> []) @
    collect_function_refs_stmts funcs for_body
  | While (cond, body) ->
    collect_function_refs_expr funcs cond @ collect_function_refs_stmts funcs body
  | Print args | Allocate (_, args) ->
    List.concat_map (collect_function_refs_expr funcs) args

and collect_function_refs_expr funcs = function
  | Var name when Hashtbl.mem funcs name -> [name]
  | Call (name, args) ->
    name :: List.concat_map (collect_function_refs_expr funcs) args
  | BinOp (_, l, r) ->
    collect_function_refs_expr funcs l @ collect_function_refs_expr funcs r
  | UnaryOp (_, e) -> collect_function_refs_expr funcs e
  | Index (e, subs) ->
    collect_function_refs_expr funcs e @ List.concat_map (collect_function_refs_subscript funcs) subs
  | CoarrayIndex (e, idxs) ->
    collect_function_refs_expr funcs e @ List.concat_map (collect_function_refs_expr funcs) idxs
  | FieldAccess (e, _) -> collect_function_refs_expr funcs e
  | ArrayLit elems -> List.concat_map (collect_function_refs_expr funcs) elems
  | FString parts -> List.concat_map (fun p -> match p with FStrExpr (e, _) -> collect_function_refs_expr funcs e | FStrLit _ -> []) parts
  | RangeExpr (start_e, stop_e, step_e) ->
    collect_function_refs_expr funcs start_e @
    collect_function_refs_expr funcs stop_e @
    (match step_e with Some e -> collect_function_refs_expr funcs e | None -> [])
  | IntLit _ | FloatLit _ | BoolLit _ | StringLit _ | Var _ -> []

and collect_function_refs_subscript funcs = function
  | IndexSubscript e -> collect_function_refs_expr funcs e
  | SliceSubscript (start_e, stop_e, step_e) ->
    (match start_e with Some e -> collect_function_refs_expr funcs e | None -> []) @
    (match stop_e with Some e -> collect_function_refs_expr funcs e | None -> []) @
    (match step_e with Some e -> collect_function_refs_expr funcs e | None -> [])

let collect_function_refs_global_init funcs = function
  | GlobalVarDecl (_, _, Some e) -> collect_function_refs_expr funcs e
  | GlobalVarDecl (_, _, None) | FuncDef _ | StructDef _ | Import _ -> []

let reachable_function_names (program : Ast.program) =
  let funcs = Hashtbl.create 64 in
  List.iter (function
    | FuncDef fd -> Hashtbl.replace funcs fd.func_name fd
    | _ -> ()
  ) program;
  if not (Hashtbl.mem funcs "main") then
    None
  else begin
    let seen = Hashtbl.create 64 in
    let rec visit name =
      if Hashtbl.mem seen name then ()
      else begin
        Hashtbl.replace seen name true;
        match Hashtbl.find_opt funcs name with
        | Some fd ->
          List.iter visit (collect_calls_stmts fd.body);
          List.iter visit (collect_function_refs_stmts funcs fd.body)
        | None -> ()
      end
    in
    visit "main";
    List.iter (fun d -> List.iter visit (collect_calls_global_init d)) program;
    List.iter (fun d -> List.iter visit (collect_function_refs_global_init funcs d)) program;
    (* Compiler-lowered helpers in support.geom_cartesian emit calls to other
       support helpers that the AST walk above cannot see (their FortScript
       bodies are `pass` stubs). Keep those callees alive whenever the
       triggering lowered helper is reachable. *)
    let lowered_callee_deps = [
      ("geom_cartesian_refine_cell", "geom_cartesian_find_imbalance");
      ("geom_cartesian_refine_to_sdf", "geom_cartesian_find_imbalance");
      ("geom_cartesian_coarsen_cell", "geom_cartesian_find_imbalance");
      (* All lowered refine/coarsen helpers rebuild the neighbor table via the
         fast locate-based routine, which in turn calls geom_cartesian_locate.
         Keep both alive when any triggering helper is reachable. *)
      ("geom_cartesian_refine_cell", "geom_cartesian_rebuild_neighbors");
      ("geom_cartesian_refine_to_sdf", "geom_cartesian_rebuild_neighbors");
      ("geom_cartesian_refine_band", "geom_cartesian_rebuild_neighbors");
      ("geom_cartesian_coarsen_cell", "geom_cartesian_rebuild_neighbors");
    ] in
    List.iter (fun (caller, callee) ->
      if Hashtbl.mem seen caller then visit callee
    ) lowered_callee_deps;
    Some seen
  end

let function_is_reachable reachable fd =
  match reachable with
  | None -> true
  | Some names -> Hashtbl.mem names fd.func_name

(* Find all functions called (transitively) from parallel loops *)
let compute_pure_functions (program : Ast.program) =
  Hashtbl.clear pure_functions;
  (* Build a map from func name -> body *)
  let func_bodies = Hashtbl.create 16 in
  List.iter (fun d ->
    match d with
    | FuncDef fd -> Hashtbl.add func_bodies fd.func_name fd.body
    | _ -> ()
  ) program;
  (* Collect direct calls from parallel loop bodies *)
  let rec find_par_calls stmts =
    List.concat_map (fun s ->
      match s with
      | For { for_body; parallel = true; _ } ->
        collect_calls_stmts for_body
      | For { for_body; _ } -> find_par_calls for_body
      | If { body; elifs; else_body; _ } ->
        find_par_calls body @
        List.concat_map (fun (_, b) -> find_par_calls b) elifs @
        find_par_calls else_body
      | While (_, body) -> find_par_calls body
      | _ -> []
    ) stmts
  in
  let needs_pure = Hashtbl.create 16 in
  (* Seed: direct calls from @par blocks *)
  List.iter (fun d ->
    match d with
    | FuncDef fd ->
      let calls = find_par_calls fd.body in
      List.iter (fun c -> Hashtbl.replace needs_pure c true) calls
    | _ -> ()
  ) program;
  (* Seed: co_reduce operation arguments must be pure in Fortran. *)
  let rec find_co_reduce_ops stmts =
    List.concat_map (fun s ->
      match s with
      | ExprStmt (Call ("co_reduce", [_; Var op_name])) -> [op_name]
      | If { body; elifs; else_body; _ } ->
        find_co_reduce_ops body @
        List.concat_map (fun (_, b) -> find_co_reduce_ops b) elifs @
        find_co_reduce_ops else_body
      | For { for_body; _ } -> find_co_reduce_ops for_body
      | While (_, body) -> find_co_reduce_ops body
      | _ -> []
    ) stmts
  in
  List.iter (fun d ->
    match d with
    | FuncDef fd ->
      let ops = find_co_reduce_ops fd.body in
      List.iter (fun c -> Hashtbl.replace needs_pure c true) ops
    | _ -> ()
  ) program;
  (* Transitive closure: if a pure function calls another user function, that one must also be pure *)
  let changed = ref true in
  while !changed do
    changed := false;
    Hashtbl.iter (fun name _ ->
      match Hashtbl.find_opt func_bodies name with
      | Some body ->
        let calls = collect_calls_stmts body in
        List.iter (fun c ->
          if Hashtbl.mem func_bodies c && not (Hashtbl.mem needs_pure c) then begin
            Hashtbl.replace needs_pure c true;
            changed := true
          end
        ) calls
      | None -> ()
    ) needs_pure
  done;
  Hashtbl.iter (fun k v -> Hashtbl.replace pure_functions k v) needs_pure

let add_unique_name names name =
  if List.mem name names then names else names @ [name]

let rec vars_in_expr = function
  | IntLit _ | FloatLit _ | BoolLit _ | StringLit _ -> []
  | FString parts -> List.concat_map (fun p -> match p with FStrExpr (e, _) -> vars_in_expr e | FStrLit _ -> []) parts
  | Var name -> [name]
  | BinOp (_, l, r) -> vars_in_expr l @ vars_in_expr r
  | UnaryOp (_, e) -> vars_in_expr e
  | Call (_, args) -> List.concat_map vars_in_expr args
  | Index (e, subs) -> vars_in_expr e @ List.concat_map vars_in_subscript subs
  | CoarrayIndex (e, idxs) -> vars_in_expr e @ List.concat_map vars_in_expr idxs
  | FieldAccess (e, _) -> vars_in_expr e
  | ArrayLit elems -> List.concat_map vars_in_expr elems
  | RangeExpr (start_e, stop_e, step_e) ->
    vars_in_expr start_e @
    vars_in_expr stop_e @
    (match step_e with Some e -> vars_in_expr e | None -> [])

and vars_in_subscript = function
  | IndexSubscript e -> vars_in_expr e
  | SliceSubscript (start_e, stop_e, step_e) ->
    (match start_e with Some e -> vars_in_expr e | None -> []) @
    (match stop_e with Some e -> vars_in_expr e | None -> []) @
    (match step_e with Some e -> vars_in_expr e | None -> [])

let rec vars_in_stmt = function
  | Assign (target, value) -> vars_in_expr target @ vars_in_expr value
  | VarDecl (_, _, Some init) -> vars_in_expr init
  | VarDecl (_, _, None) -> []
  | AugAssign (_, target, value) -> vars_in_expr target @ vars_in_expr value
  | Return (Some e) -> vars_in_expr e
  | Return None -> []
  | Break -> []
  | If { cond; body; elifs; else_body } ->
    vars_in_expr cond @
    List.concat_map vars_in_stmt body @
    List.concat_map (fun (elif_cond, elif_body) ->
      vars_in_expr elif_cond @ List.concat_map vars_in_stmt elif_body
    ) elifs @
    List.concat_map vars_in_stmt else_body
  | For { start_expr; end_expr; step_expr; for_body; _ } ->
    vars_in_expr start_expr @
    vars_in_expr end_expr @
    (match step_expr with Some e -> vars_in_expr e | None -> []) @
    List.concat_map vars_in_stmt for_body
  | While (cond, body) ->
    vars_in_expr cond @ List.concat_map vars_in_stmt body
  | ExprStmt e -> vars_in_expr e
  | Print args -> List.concat_map vars_in_expr args
  | SyncAll -> []
  | Allocate (_, dims) -> List.concat_map vars_in_expr dims
  | Pass -> []

let rec collect_local_decl_names stmts =
  List.concat_map (function
    | VarDecl (name, _, _) -> [name]
    | If { body; elifs; else_body; _ } ->
      collect_local_decl_names body @
      List.concat_map (fun (_, elif_body) -> collect_local_decl_names elif_body) elifs @
      collect_local_decl_names else_body
    | For { var; for_body; _ } ->
      var :: collect_local_decl_names for_body
    | While (_, body) ->
      collect_local_decl_names body
    | Assign _ | AugAssign _ | Return _ | Break | ExprStmt _ | Print _
    | SyncAll | Allocate _ | Pass ->
      []
  ) stmts

let free_vars_in_body stmts excluded =
  let raw_names = List.concat_map vars_in_stmt stmts in
  List.fold_left (fun acc name ->
    if List.mem name excluded then acc else add_unique_name acc name
  ) [] raw_names

let collect_gpu_kernel_params loop helpers =
  let body_locals = collect_local_decl_names loop.for_body in
  let reduction_vars =
    List.concat_map (fun spec -> spec.reduce_vars) loop.reduce_specs
  in
  let loop_names =
    vars_in_expr loop.start_expr @
    vars_in_expr loop.end_expr @
    (match loop.step_expr with Some e -> vars_in_expr e | None -> []) @
    List.concat_map vars_in_stmt loop.for_body @
    loop.local_init_vars @
    reduction_vars
  in
  let excluded = loop.var :: body_locals @ loop.local_vars in
  let loop_params = List.fold_left (fun acc name ->
    if List.mem name excluded then acc else add_unique_name acc name
  ) [] loop_names
  in
  List.fold_left (fun acc helper_fd ->
    let helper_excluded =
      helper_fd.func_name ::
      List.map (fun p -> p.param_name) helper_fd.params @
      collect_local_decl_names helper_fd.body
    in
    List.fold_left add_unique_name acc (free_vars_in_body helper_fd.body helper_excluded)
  ) loop_params helpers

let collect_gpu_kernel_helpers loop =
  let direct_calls = collect_calls_stmts loop.for_body in
  let seen = Hashtbl.create 16 in
  let ordered = ref [] in
  let rec visit name =
    if Hashtbl.mem seen name then ()
    else begin
      Hashtbl.add seen name true;
      match Hashtbl.find_opt user_functions name with
      | Some fd ->
        ordered := !ordered @ [fd];
        List.iter visit (collect_calls_stmts fd.body)
      | None -> ()
    end
  in
  List.iter visit direct_calls;
  !ordered

let rec stmt_contains_gpu = function
  | For { gpu; for_body; _ } ->
    gpu || List.exists stmt_contains_gpu for_body
  | If { body; elifs; else_body; _ } ->
    List.exists stmt_contains_gpu body ||
    List.exists (fun (_, elif_body) -> List.exists stmt_contains_gpu elif_body) elifs ||
    List.exists stmt_contains_gpu else_body
  | While (_, body) ->
    List.exists stmt_contains_gpu body
  | Assign _ | VarDecl _ | AugAssign _ | Return _ | Break
  | ExprStmt _ | Print _ | SyncAll | Allocate _ | Pass ->
    false

(* Collect all For-loop variables nested inside a statement list. *)
let rec collect_inner_loop_vars stmts =
  List.concat_map (fun stmt ->
    match stmt with
    | For { var; for_body; _ } ->
        var :: collect_inner_loop_vars for_body  (* Include this var and recurse. *)
    | If { body; elifs; else_body; _ } ->
        collect_inner_loop_vars body @
        List.concat_map (fun (_, b) -> collect_inner_loop_vars b) elifs @
        collect_inner_loop_vars else_body
    | While (_, body) ->
        collect_inner_loop_vars body
    | _ -> []
  ) stmts

(* Collect every name that is the target of a whole-variable write anywhere in
   the body: a plain assignment to a bare variable, an augmented assignment to a
   bare variable, or a local declaration. Element writes such as a[i] = ... are
   not whole-variable writes and are skipped. Used to derive the do concurrent
   local() / OpenMP private() set for a parallel loop. *)
let rec collect_assigned_var_names stmts =
  List.concat_map (function
    | Assign (Var name, _) -> [name]
    | AugAssign (_, Var name, _) -> [name]
    | VarDecl (name, _, _) -> [name]
    | If { body; elifs; else_body; _ } ->
        collect_assigned_var_names body @
        List.concat_map (fun (_, b) -> collect_assigned_var_names b) elifs @
        collect_assigned_var_names else_body
    | For { for_body; _ } -> collect_assigned_var_names for_body
    | While (_, body) -> collect_assigned_var_names body
    | _ -> []
  ) stmts

(* Decide whether an assigned scalar can be a plain do concurrent local /
   OpenMP private (true) or must use local_init / firstprivate (false).

   It is only safe as a plain local when the first top-level statement that
   references the name is an unconditional whole-variable write that does not
   read the name on its right-hand side. Any other first reference (a read, an
   augmented assignment, or a reference nested inside a conditional or inner
   loop) is conservatively treated as read-before-write, so the variable carries
   its pre-loop value in via local_init / firstprivate. That value is always
   defined because these temporaries are declared and initialized at procedure
   scope before the loop. *)
let assigned_clean_first name stmts =
  let reads_name e = List.mem name (vars_in_expr e) in
  let rec scan = function
    | [] -> false
    | stmt :: rest ->
      if not (List.mem name (vars_in_stmt stmt)) then scan rest
      else
        (match stmt with
         | Assign (Var n, rhs) when n = name -> not (reads_name rhs)
         | VarDecl (n, _, Some e) when n = name -> not (reads_name e)
         | VarDecl (n, _, None) when n = name -> true
         | _ -> false)
  in
  scan stmts

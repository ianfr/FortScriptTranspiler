open Ast
open Semantic_types

(* Validators for slice-step constraints and the various builtin/stdlib call
   shapes: plotting, HDF5, XDMF, and support.linalg/support.random stubs. *)

(* Check slice-specific constraints. *)
let validate_slices program =
  let errors = ref [] in
  let rec check_expr = function
    | FString parts -> List.iter (fun p -> match p with FStrExpr (e, _) -> check_expr e | FStrLit _ -> ()) parts
    | IntLit _ | FloatLit _ | BoolLit _ | StringLit _ | Var _ -> ()
    | BinOp (_, l, r) ->
      check_expr l;
      check_expr r
    | UnaryOp (_, e) -> check_expr e
    | Call (_, args) -> List.iter check_expr args
    | Index (e, subs) ->
      check_expr e;
      List.iter check_subscript subs
    | CoarrayIndex (e, idxs) ->
      check_expr e;
      List.iter check_expr idxs
    | FieldAccess (e, _) -> check_expr e
    | ArrayLit elems -> List.iter check_expr elems
    | RangeExpr (start_e, stop_e, step_e) ->
      check_expr start_e;
      check_expr stop_e;
      (match step_e with Some e -> check_expr e | None -> ())
  and check_subscript = function
    | IndexSubscript e -> check_expr e
    | SliceSubscript (start_e, stop_e, step_e) ->
      (match start_e with Some e -> check_expr e | None -> ());
      (match stop_e with Some e -> check_expr e | None -> ());
      (match step_e with
       | Some e ->
         check_expr e;
         (match try_const_int e with
          | Some n when n <= 0 ->
            errors := "Slice steps must be positive when statically known" :: !errors
          | _ -> ())
       | None -> ())
  in
  let rec check_stmt = function
    | Assign (target, value) ->
      check_expr target;
      check_expr value
    | VarDecl (_, _, Some e) -> check_expr e
    | VarDecl (_, _, None) -> ()
    | AugAssign (_, target, value) ->
      check_expr target;
      check_expr value
    | Return (Some e) -> check_expr e
    | Return None -> ()
    | If { cond; body; elifs; else_body } ->
      check_expr cond;
      List.iter check_stmt body;
      List.iter (fun (elif_cond, elif_body) ->
        check_expr elif_cond;
        List.iter check_stmt elif_body
      ) elifs;
      List.iter check_stmt else_body
    | For { start_expr; end_expr; step_expr; for_body; _ } ->
      check_expr start_expr;
      check_expr end_expr;
      (match step_expr with Some e -> check_expr e | None -> ());
      List.iter check_stmt for_body
    | While (cond, body) ->
      check_expr cond;
      List.iter check_stmt body
    | ExprStmt e -> check_expr e
    | Print args -> List.iter check_expr args
    | SyncAll -> ()
    | Allocate (_, dims) -> List.iter check_expr dims
    | Break -> ()
    | Pass -> ()
  in
  List.iter (function
    | FuncDef { body; _ } -> List.iter check_stmt body
    | GlobalVarDecl (_, _, Some e) -> check_expr e
    | GlobalVarDecl (_, _, None) | StructDef _ | Import _ -> ()
  ) program;
  !errors

(* Validate append() before generic function-call checks. *)
let validate_append_calls program =
  let errors = ref [] in
  let current_param_names = ref StringSet.empty in
  let global_env =
    List.fold_left (fun env decl ->
      match decl with
      | GlobalVarDecl (name, typ, _) -> StringMap.add name typ env
      | _ -> env
    ) StringMap.empty program
  in
  let unsupported_elem_type = function
    | TString | TArray _ | TCoarray _ | TFunc _ | TVoid -> true
    | TInt | TFloat | TBool | TStruct _ | TGeneric _ -> false
  in
  let check_append_target env = function
    | Var arr ->
      if StringSet.mem arr !current_param_names then
        errors := "append() target cannot be a function parameter" :: !errors
      else
      (match StringMap.find_opt arr env with
       | Some (TArray (elem_t, [DeferredDim])) ->
         if unsupported_elem_type elem_t then
           errors := "append() target element type is not supported" :: !errors
       | Some (TCoarray _) ->
         errors := "append() does not support coarrays" :: !errors
       | Some (TArray _) ->
         errors := "append() expects a 1D deferred-shape array" :: !errors
       | Some _ ->
         errors := "append() expects an array target" :: !errors
       | None ->
         errors := ("append() target must be a declared array variable: " ^ arr) :: !errors)
    | _ ->
      errors := "append() target must be a bare array variable" :: !errors
  in
  let rec check_expr = function
    | FString parts -> List.iter (fun p -> match p with FStrExpr (e, _) -> check_expr e | FStrLit _ -> ()) parts
    | IntLit _ | FloatLit _ | BoolLit _ | StringLit _ | Var _ -> ()
    | BinOp (_, l, r) ->
      check_expr l;
      check_expr r
    | UnaryOp (_, e) -> check_expr e
    | Call ("append", args) ->
      errors := "append() can only be used as a standalone statement" :: !errors;
      List.iter check_expr args
    | Call (_, args) -> List.iter check_expr args
    | Index (e, subs) ->
      check_expr e;
      List.iter check_subscript subs
    | CoarrayIndex (e, idxs) ->
      check_expr e;
      List.iter check_expr idxs
    | FieldAccess (e, _) -> check_expr e
    | ArrayLit elems -> List.iter check_expr elems
    | RangeExpr (start_e, stop_e, step_e) ->
      check_expr start_e;
      check_expr stop_e;
      (match step_e with Some e -> check_expr e | None -> ())
  and check_subscript = function
    | IndexSubscript e -> check_expr e
    | SliceSubscript (start_e, stop_e, step_e) ->
      (match start_e with Some e -> check_expr e | None -> ());
      (match stop_e with Some e -> check_expr e | None -> ());
      (match step_e with Some e -> check_expr e | None -> ())
  in
  let rec collect_stmt env = function
    | VarDecl (name, typ, _) -> StringMap.add name typ env
    | If { body; elifs; else_body; _ } ->
      let env = collect_stmts env body in
      let env =
        List.fold_left (fun env (_, elif_body) ->
          collect_stmts env elif_body
        ) env elifs
      in
      collect_stmts env else_body
    | For { for_body; _ } -> collect_stmts env for_body
    | While (_, body) -> collect_stmts env body
    | Assign _ | AugAssign _ | Return _ | Break | ExprStmt _ | Print _ | SyncAll
    | Allocate _ | Pass -> env
  and collect_stmts env stmts =
    List.fold_left collect_stmt env stmts
  in
  let rec check_stmt env = function
    | ExprStmt (Call ("append", args)) ->
      (match args with
       | [target; value] ->
         check_append_target env target;
         check_expr target;
         check_expr value
       | _ ->
         errors := "append() expects 2 arguments: array, value" :: !errors;
         List.iter check_expr args);
      env
    | Assign (target, value) ->
      check_expr target;
      check_expr value;
      env
    | VarDecl (name, typ, init) ->
      (match init with Some e -> check_expr e | None -> ());
      StringMap.add name typ env
    | AugAssign (_, target, value) ->
      check_expr target;
      check_expr value;
      env
    | Return (Some e) ->
      check_expr e;
      env
    | Return None -> env
    | If { cond; body; elifs; else_body } ->
      check_expr cond;
      ignore (check_stmts env body);
      List.iter (fun (elif_cond, elif_body) ->
        check_expr elif_cond;
        ignore (check_stmts env elif_body)
      ) elifs;
      ignore (check_stmts env else_body);
      env
    | For { var; start_expr; end_expr; step_expr; for_body; _ } ->
      check_expr start_expr;
      check_expr end_expr;
      (match step_expr with Some e -> check_expr e | None -> ());
      ignore (check_stmts (StringMap.add var TInt env) for_body);
      env
    | While (cond, body) ->
      check_expr cond;
      ignore (check_stmts env body);
      env
    | ExprStmt e ->
      check_expr e;
      env
    | Print args ->
      List.iter check_expr args;
      env
    | SyncAll -> env
    | Allocate (_, dims) ->
      List.iter check_expr dims;
      env
    | Break -> env
    | Pass -> env
  and check_stmts env stmts =
    List.fold_left check_stmt env stmts
  in
  List.iter (function
    | FuncDef { params; body; _ } ->
      let old_param_names = !current_param_names in
      current_param_names :=
        List.fold_left (fun names p ->
          StringSet.add p.param_name names
        ) StringSet.empty params;
      let env =
        List.fold_left (fun env p ->
          StringMap.add p.param_name p.param_type env
        ) global_env params
      in
      let env = collect_stmts env body in
      ignore (check_stmts env body);
      current_param_names := old_param_names
    | GlobalVarDecl (_, _, Some e) -> check_expr e
    | GlobalVarDecl (_, _, None) | StructDef _ | Import _ -> ()
  ) program;
  !errors

(* Check builtin plotting usage. *)
let validate_plotting program =
  let errors = ref [] in
  let invalid_plot_arity arity =
    arity <> 3 && arity <> 4 && arity <> 6
  in
  let rec check_expr = function
    | FString parts -> List.iter (fun p -> match p with FStrExpr (e, _) -> check_expr e | FStrLit _ -> ()) parts
    | IntLit _ | FloatLit _ | BoolLit _ | StringLit _ | Var _ -> ()
    | BinOp (_, l, r) ->
      check_expr l;
      check_expr r
    | UnaryOp (_, e) -> check_expr e
    | Call ("plot", _) ->
      errors := "plot() can only be used as a standalone statement" :: !errors
    | Call (_, args) -> List.iter check_expr args
    | Index (e, subs) ->
      check_expr e;
      List.iter check_subscript subs
    | CoarrayIndex (e, idxs) ->
      check_expr e;
      List.iter check_expr idxs
    | FieldAccess (e, _) -> check_expr e
    | ArrayLit elems -> List.iter check_expr elems
    | RangeExpr (start_e, stop_e, step_e) ->
      check_expr start_e;
      check_expr stop_e;
      (match step_e with Some e -> check_expr e | None -> ())
  and check_subscript = function
    | IndexSubscript e -> check_expr e
    | SliceSubscript (start_e, stop_e, step_e) ->
      (match start_e with Some e -> check_expr e | None -> ());
      (match stop_e with Some e -> check_expr e | None -> ());
      (match step_e with Some e -> check_expr e | None -> ())
  in
  let rec check_stmt = function
    | ExprStmt (Call ("plot", args)) ->
      if invalid_plot_arity (List.length args) then
        errors := "plot() expects 3, 4, or 6 arguments" :: !errors;
      List.iter check_expr args
    | Assign (target, value) ->
      check_expr target;
      check_expr value
    | VarDecl (_, _, Some e) -> check_expr e
    | VarDecl (_, _, None) -> ()
    | AugAssign (_, target, value) ->
      check_expr target;
      check_expr value
    | Return (Some e) -> check_expr e
    | Return None -> ()
    | If { cond; body; elifs; else_body } ->
      check_expr cond;
      List.iter check_stmt body;
      List.iter (fun (elif_cond, elif_body) ->
        check_expr elif_cond;
        List.iter check_stmt elif_body
      ) elifs;
      List.iter check_stmt else_body
    | For { start_expr; end_expr; step_expr; for_body; _ } ->
      check_expr start_expr;
      check_expr end_expr;
      (match step_expr with Some e -> check_expr e | None -> ());
      List.iter check_stmt for_body
    | While (cond, body) ->
      check_expr cond;
      List.iter check_stmt body
    | ExprStmt e -> check_expr e
    | Print args -> List.iter check_expr args
    | SyncAll -> ()
    | Allocate (_, dims) -> List.iter check_expr dims
    | Break -> ()
    | Pass -> ()
  in
  List.iter (function
    | FuncDef { body; _ } -> List.iter check_stmt body
    | GlobalVarDecl (_, _, Some e) -> check_expr e
    | GlobalVarDecl (_, _, None) | StructDef _ | Import _ -> ()
  ) program;
  !errors

(* Enforce that h5write/h5read are statement-only (the third argument
   would otherwise need to be modifiable for h5read) and have arity 3. *)
let validate_h5_calls program =
  let errors = ref [] in
  let h5_names = ["h5write"; "h5read"] in
  let is_h5 name = List.mem name h5_names in
  let rec check_expr = function
    | FString parts -> List.iter (fun p -> match p with FStrExpr (e, _) -> check_expr e | FStrLit _ -> ()) parts
    | IntLit _ | FloatLit _ | BoolLit _ | StringLit _ | Var _ -> ()
    | BinOp (_, l, r) ->
      check_expr l;
      check_expr r
    | UnaryOp (_, e) -> check_expr e
    | Call (name, _) when is_h5 name ->
      errors := (name ^ "() can only be used as a standalone statement") :: !errors
    | Call (_, args) -> List.iter check_expr args
    | Index (e, subs) ->
      check_expr e;
      List.iter check_subscript subs
    | CoarrayIndex (e, idxs) ->
      check_expr e;
      List.iter check_expr idxs
    | FieldAccess (e, _) -> check_expr e
    | ArrayLit elems -> List.iter check_expr elems
    | RangeExpr (start_e, stop_e, step_e) ->
      check_expr start_e;
      check_expr stop_e;
      (match step_e with Some e -> check_expr e | None -> ())
  and check_subscript = function
    | IndexSubscript e -> check_expr e
    | SliceSubscript (start_e, stop_e, step_e) ->
      (match start_e with Some e -> check_expr e | None -> ());
      (match stop_e with Some e -> check_expr e | None -> ());
      (match step_e with Some e -> check_expr e | None -> ())
  in
  let rec check_stmt = function
    | ExprStmt (Call (name, args)) when is_h5 name ->
      if List.length args <> 3 then
        errors := (name ^ "() expects 3 arguments: filename, dataset_name, value") :: !errors;
      List.iter check_expr args
    | Assign (target, value) ->
      check_expr target;
      check_expr value
    | VarDecl (_, _, Some e) -> check_expr e
    | VarDecl (_, _, None) -> ()
    | AugAssign (_, target, value) ->
      check_expr target;
      check_expr value
    | Return (Some e) -> check_expr e
    | Return None -> ()
    | If { cond; body; elifs; else_body } ->
      check_expr cond;
      List.iter check_stmt body;
      List.iter (fun (elif_cond, elif_body) ->
        check_expr elif_cond;
        List.iter check_stmt elif_body
      ) elifs;
      List.iter check_stmt else_body
    | For { start_expr; end_expr; step_expr; for_body; _ } ->
      check_expr start_expr;
      check_expr end_expr;
      (match step_expr with Some e -> check_expr e | None -> ());
      List.iter check_stmt for_body
    | While (cond, body) ->
      check_expr cond;
      List.iter check_stmt body
    | ExprStmt e -> check_expr e
    | Print args -> List.iter check_expr args
    | SyncAll -> ()
    | Allocate (_, dims) -> List.iter check_expr dims
    | Break -> ()
    | Pass -> ()
  in
  List.iter (function
    | FuncDef { body; _ } -> List.iter check_stmt body
    | GlobalVarDecl (_, _, Some e) -> check_expr e
    | GlobalVarDecl (_, _, None) | StructDef _ | Import _ -> ()
  ) program;
  !errors

(* Check XDMF builtin usage and per-builtin arity. *)
let validate_xdmf_calls program =
  let errors = ref [] in
  let arity_message = function
    | "xdmf_add" -> "xdmf_add() expects 3 arguments: xml_str, field_name, field_array"
    | "xdmf_add_xyz" -> "xdmf_add_xyz() expects 4 arguments: xml_str, x, y, z"
    | "xdmf_add_unstructured" -> "xdmf_add_unstructured() expects 3 arguments: xml_str, points, connectivity"
    | "xdmf_add_cell" -> "xdmf_add_cell() expects 3 arguments: xml_str, field_name, field_array"
    | "xdmf_write" -> "xdmf_write() expects 3 arguments: xdmf_filename, h5_filename, xml_str"
    | name -> name ^ "() has an unknown signature"
  in
  let is_xdmf = function
    | "xdmf_add" | "xdmf_add_xyz" | "xdmf_add_unstructured" | "xdmf_add_cell" | "xdmf_write" -> true
    | _ -> false
  in
  let rec check_expr = function
    | FString parts -> List.iter (fun p -> match p with FStrExpr (e, _) -> check_expr e | FStrLit _ -> ()) parts
    | IntLit _ | FloatLit _ | BoolLit _ | StringLit _ | Var _ -> ()
    | BinOp (_, l, r) ->
      check_expr l;
      check_expr r
    | UnaryOp (_, e) -> check_expr e
    | Call (name, _) when is_xdmf name ->
      errors := (name ^ "() can only be used as a standalone statement") :: !errors
    | Call (_, args) -> List.iter check_expr args
    | Index (e, subs) ->
      check_expr e;
      List.iter check_subscript subs
    | CoarrayIndex (e, idxs) ->
      check_expr e;
      List.iter check_expr idxs
    | FieldAccess (e, _) -> check_expr e
    | ArrayLit elems -> List.iter check_expr elems
    | RangeExpr (start_e, stop_e, step_e) ->
      check_expr start_e;
      check_expr stop_e;
      (match step_e with Some e -> check_expr e | None -> ())
  and check_subscript = function
    | IndexSubscript e -> check_expr e
    | SliceSubscript (start_e, stop_e, step_e) ->
      (match start_e with Some e -> check_expr e | None -> ());
      (match stop_e with Some e -> check_expr e | None -> ());
      (match step_e with Some e -> check_expr e | None -> ())
  in
  let rec check_stmt = function
    | ExprStmt (Call (name, args)) when is_xdmf name ->
      let expected_arity =
        match name with
        | "xdmf_add" -> 3
        | "xdmf_add_xyz" -> 4
        | "xdmf_add_unstructured" -> 3
        | "xdmf_add_cell" -> 3
        | "xdmf_write" -> 3
        | _ -> 0
      in
      if List.length args <> expected_arity then
        errors := arity_message name :: !errors;
      List.iter check_expr args
    | Assign (target, value) ->
      check_expr target;
      check_expr value
    | VarDecl (_, _, Some e) -> check_expr e
    | VarDecl (_, _, None) -> ()
    | AugAssign (_, target, value) ->
      check_expr target;
      check_expr value
    | Return (Some e) -> check_expr e
    | Return None -> ()
    | If { cond; body; elifs; else_body } ->
      check_expr cond;
      List.iter check_stmt body;
      List.iter (fun (c, b) ->
        check_expr c;
        List.iter check_stmt b
      ) elifs;
      List.iter check_stmt else_body
    | For { start_expr; end_expr; step_expr; for_body; _ } ->
      check_expr start_expr;
      check_expr end_expr;
      (match step_expr with Some e -> check_expr e | None -> ());
      List.iter check_stmt for_body
    | While (cond, body) ->
      check_expr cond;
      List.iter check_stmt body
    | ExprStmt e -> check_expr e
    | Print args -> List.iter check_expr args
    | SyncAll -> ()
    | Allocate (_, dims) -> List.iter check_expr dims
    | Break -> ()
    | Pass -> ()
  in
  List.iter (function
    | FuncDef { body; _ } -> List.iter check_stmt body
    | GlobalVarDecl (_, _, Some e) -> check_expr e
    | GlobalVarDecl (_, _, None) | StructDef _ | Import _ -> ()
  ) program;
  !errors

(* Check standard-library stubs with custom lowering. *)
let validate_stdlib_calls program =
  let errors = ref [] in
  let has_lapack_qr =
    List.exists (function
      | FuncDef fd -> is_lapack_qr_stub fd
      | _ -> false
    ) program
  in
  let has_lapack_svd =
    List.exists (function
      | FuncDef fd -> is_lapack_svd_stub fd
      | _ -> false
    ) program
  in
  let has_lapack_solve =
    List.exists (function
      | FuncDef fd -> is_lapack_solve_stub fd
      | _ -> false
    ) program
  in
  let has_lapack_eig =
    List.exists (function
      | FuncDef fd -> is_lapack_eig_stub fd
      | _ -> false
    ) program
  in
  let has_random_fill =
    List.exists (function
      | FuncDef fd -> is_random_fill_stub fd
      | _ -> false
    ) program
  in
  let has_uniform_fill =
    List.exists (function
      | FuncDef fd -> is_uniform_fill_stub fd
      | _ -> false
    ) program
  in
  let has_random_seed =
    List.exists (function
      | FuncDef fd -> is_random_seed_stub fd
      | _ -> false
    ) program
  in
  let rec check_expr = function
    | FString parts -> List.iter (fun p -> match p with FStrExpr (e, _) -> check_expr e | FStrLit _ -> ()) parts
    | IntLit _ | FloatLit _ | BoolLit _ | StringLit _ | Var _ -> ()
    | BinOp (_, l, r) ->
      check_expr l;
      check_expr r
    | UnaryOp (_, e) -> check_expr e
    | Call ("qr", _) when has_lapack_qr ->
      errors := "qr() from support.linalg can only be used as a standalone statement" :: !errors
    | Call ("svd", _) when has_lapack_svd ->
      errors := "svd() from support.linalg can only be used as a standalone statement" :: !errors
    | Call ("solve", _) when has_lapack_solve ->
      errors := "solve() from support.linalg can only be used as a standalone statement" :: !errors
    | Call ("eig", _) when has_lapack_eig ->
      errors := "eig() from support.linalg can only be used as a standalone statement" :: !errors
    | Call ("random_fill", _) when has_random_fill ->
      errors := "random_fill() from support.random can only be used as a standalone statement" :: !errors
    | Call ("uniform_fill", _) when has_uniform_fill ->
      errors := "uniform_fill() from support.random can only be used as a standalone statement" :: !errors
    | Call ("seed", _) when has_random_seed ->
      errors := "seed() from support.random can only be used as a standalone statement" :: !errors
    | Call (_, args) -> List.iter check_expr args
    | Index (e, subs) ->
      check_expr e;
      List.iter check_subscript subs
    | CoarrayIndex (e, idxs) ->
      check_expr e;
      List.iter check_expr idxs
    | FieldAccess (e, _) -> check_expr e
    | ArrayLit elems -> List.iter check_expr elems
    | RangeExpr (start_e, stop_e, step_e) ->
      check_expr start_e;
      check_expr stop_e;
      (match step_e with Some e -> check_expr e | None -> ())
  and check_subscript = function
    | IndexSubscript e -> check_expr e
    | SliceSubscript (start_e, stop_e, step_e) ->
      (match start_e with Some e -> check_expr e | None -> ());
      (match stop_e with Some e -> check_expr e | None -> ());
      (match step_e with Some e -> check_expr e | None -> ())
  in
  let rec check_stmt = function
    | ExprStmt (Call ("qr", args)) when has_lapack_qr ->
      if List.length args <> 3 then
        errors := "qr() from support.linalg expects 3 arguments: a, q, r" :: !errors;
      List.iter check_expr args
    | ExprStmt (Call ("svd", args)) when has_lapack_svd ->
      if List.length args <> 4 then
        errors := "svd() from support.linalg expects 4 arguments: a, u, s, vt" :: !errors;
      List.iter check_expr args
    | ExprStmt (Call ("solve", args)) when has_lapack_solve ->
      if List.length args <> 3 then
        errors := "solve() from support.linalg expects 3 arguments: a, b, x" :: !errors;
      List.iter check_expr args
    | ExprStmt (Call ("eig", args)) when has_lapack_eig ->
      if List.length args <> 4 then
        errors := "eig() from support.linalg expects 4 arguments: a, wr, wi, vr" :: !errors;
      List.iter check_expr args
    | ExprStmt (Call ("random_fill", args)) when has_random_fill ->
      if List.length args <> 1 then
        errors := "random_fill() from support.random expects 1 argument: x" :: !errors;
      List.iter check_expr args
    | ExprStmt (Call ("uniform_fill", args)) when has_uniform_fill ->
      if List.length args <> 3 then
        errors := "uniform_fill() from support.random expects 3 arguments: low, high, x" :: !errors;
      List.iter check_expr args
    | ExprStmt (Call ("seed", args)) when has_random_seed ->
      if List.length args <> 1 then
        errors := "seed() from support.random expects 1 argument: s" :: !errors;
      List.iter check_expr args
    | Assign (target, value) ->
      check_expr target;
      check_expr value
    | VarDecl (_, _, Some e) -> check_expr e
    | VarDecl (_, _, None) -> ()
    | AugAssign (_, target, value) ->
      check_expr target;
      check_expr value
    | Return (Some e) -> check_expr e
    | Return None -> ()
    | If { cond; body; elifs; else_body } ->
      check_expr cond;
      List.iter check_stmt body;
      List.iter (fun (elif_cond, elif_body) ->
        check_expr elif_cond;
        List.iter check_stmt elif_body
      ) elifs;
      List.iter check_stmt else_body
    | For { start_expr; end_expr; step_expr; for_body; _ } ->
      check_expr start_expr;
      check_expr end_expr;
      (match step_expr with Some e -> check_expr e | None -> ());
      List.iter check_stmt for_body
    | While (cond, body) ->
      check_expr cond;
      List.iter check_stmt body
    | ExprStmt e -> check_expr e
    | Print args -> List.iter check_expr args
    | SyncAll -> ()
    | Allocate (_, dims) -> List.iter check_expr dims
    | Break -> ()
    | Pass -> ()
  in
  List.iter (function
    | FuncDef { body; _ } -> List.iter check_stmt body
    | GlobalVarDecl (_, _, Some e) -> check_expr e
    | GlobalVarDecl (_, _, None) | StructDef _ | Import _ -> ()
  ) program;
  !errors

open Ast
open Semantic_types

(* Validators for parallelism-related constructs: coarrays, do concurrent
   clauses, @gpu loops, and break-statement scoping. *)

(* Check coarray-specific restrictions. *)
let validate_coarrays program =
  let errors = ref [] in
  let rec expr_uses_coarray = function
    | CoarrayIndex (target_e, idxs) ->
      let _ = expr_uses_coarray target_e in
      let _ = List.exists expr_uses_coarray idxs in
      true
    | Call (("this_image" | "num_images"
           | "co_sum" | "co_min" | "co_max" | "co_broadcast" | "co_reduce"), args) ->
      let _ = List.exists expr_uses_coarray args in
      true
    | Call (_, args) -> List.exists expr_uses_coarray args
    | BinOp (_, l, r) -> expr_uses_coarray l || expr_uses_coarray r
    | UnaryOp (_, e) -> expr_uses_coarray e
    | Index (e, subs) ->
      expr_uses_coarray e || List.exists subscript_uses_coarray subs
    | FieldAccess (e, _) -> expr_uses_coarray e
    | ArrayLit elems -> List.exists expr_uses_coarray elems
    | RangeExpr (start_e, stop_e, step_e) ->
      expr_uses_coarray start_e ||
      expr_uses_coarray stop_e ||
      (match step_e with Some e -> expr_uses_coarray e | None -> false)
    | FString parts -> List.exists (fun p -> match p with FStrExpr (e, _) -> expr_uses_coarray e | FStrLit _ -> false) parts
    | IntLit _ | FloatLit _ | BoolLit _ | StringLit _ | Var _ -> false
  and subscript_uses_coarray = function
    | IndexSubscript e -> expr_uses_coarray e
    | SliceSubscript (start_e, stop_e, step_e) ->
      (match start_e with Some e -> expr_uses_coarray e | None -> false) ||
      (match stop_e with Some e -> expr_uses_coarray e | None -> false) ||
      (match step_e with Some e -> expr_uses_coarray e | None -> false)
  and stmt_uses_coarray = function
    | Assign (target, value) ->
      expr_uses_coarray target || expr_uses_coarray value
    | VarDecl (_, _, Some e) -> expr_uses_coarray e
    | VarDecl (_, _, None) -> false
    | AugAssign (_, target, value) ->
      expr_uses_coarray target || expr_uses_coarray value
    | Return (Some e) -> expr_uses_coarray e
    | Return None -> false
    | Break -> false
    | If { cond; body; elifs; else_body } ->
      expr_uses_coarray cond ||
      List.exists stmt_uses_coarray body ||
      List.exists (fun (elif_cond, elif_body) ->
        expr_uses_coarray elif_cond || List.exists stmt_uses_coarray elif_body
      ) elifs ||
      List.exists stmt_uses_coarray else_body
    | For { start_expr; end_expr; step_expr; for_body; _ } ->
      expr_uses_coarray start_expr ||
      expr_uses_coarray end_expr ||
      (match step_expr with Some e -> expr_uses_coarray e | None -> false) ||
      List.exists stmt_uses_coarray for_body
    | While (cond, body) ->
      expr_uses_coarray cond || List.exists stmt_uses_coarray body
    | ExprStmt e -> expr_uses_coarray e
    | Print args -> List.exists expr_uses_coarray args
    | SyncAll -> true
    | Allocate (_, dims) ->
      let _ = List.exists expr_uses_coarray dims in
      true
    | Pass -> false
  in
  List.iter (function
    | Import _ -> ()
    | StructDef (struct_name, fields) ->
      List.iter (fun field ->
        if is_coarray_type field.field_type then
          errors := (Printf.sprintf "Struct %s cannot contain coarray field %s"
            struct_name field.field_name) :: !errors
      ) fields
    | FuncDef { func_name; params; return_type; body } ->
      List.iter (fun param ->
        if is_coarray_type param.param_type then
          errors := (Printf.sprintf "Function %s cannot take coarray parameter %s"
            func_name param.param_name) :: !errors
      ) params;
      if is_coarray_type return_type then
        errors := (Printf.sprintf "Function %s cannot return a coarray value" func_name) :: !errors;
      let rec check_stmt = function
        | VarDecl (name, TCoarray (TArray (_, dims), _), Some _) when List.exists is_deferred_dim dims ->
          errors := (Printf.sprintf
            "Deferred-shape coarray %s cannot be initialized at declaration; use allocate() first"
            name) :: !errors
        | If { body; elifs; else_body; _ } ->
          List.iter check_stmt body;
          List.iter (fun (_, elif_body) -> List.iter check_stmt elif_body) elifs;
          List.iter check_stmt else_body
        | For { for_body; parallel; omp; _ } when parallel || omp ->
          if List.exists stmt_uses_coarray for_body then
            errors := "Coarray operations are not allowed inside @par or @omp loops" :: !errors;
          List.iter check_stmt for_body
        | For { for_body; _ } -> List.iter check_stmt for_body
        | While (_, body) -> List.iter check_stmt body
        | _ -> ()
      in
      List.iter check_stmt body
    | GlobalVarDecl (name, TCoarray (TArray (_, dims), _), Some _) when List.exists is_deferred_dim dims ->
      errors := (Printf.sprintf
        "Deferred-shape coarray %s cannot be initialized at declaration; use allocate() first"
        name) :: !errors
    | GlobalVarDecl _ -> ()
  ) program;
  !errors

(* Check do concurrent clause syntax and typing. *)
let validate_do_concurrent_features program =
  let errors = ref [] in
  let add_binding env name typ =
    if StringMap.mem name env then env else StringMap.add name typ env
  in
  let rec collect_stmt_bindings env = function
    | VarDecl (name, typ, _) ->
      add_binding env name typ
    | If { body; elifs; else_body; _ } ->
      let env = List.fold_left collect_stmt_bindings env body in
      let env =
        List.fold_left (fun acc (_, elif_body) ->
          List.fold_left collect_stmt_bindings acc elif_body
        ) env elifs
      in
      List.fold_left collect_stmt_bindings env else_body
    | For { var; for_body; _ } ->
      let env = add_binding env var TInt in
      List.fold_left collect_stmt_bindings env for_body
    | While (_, body) ->
      List.fold_left collect_stmt_bindings env body
    | Assign _ | AugAssign _ | Return _ | Break | ExprStmt _ | Print _
    | SyncAll | Allocate _ | Pass ->
      env
  in
  let type_name = function
    | TInt -> "int"
    | TFloat -> "float"
    | TBool -> "bool"
    | TString -> "string"
    | TArray _ -> "array"
    | TCoarray _ -> "coarray"
    | TStruct name -> "struct " ^ name
    | TGeneric (base, _) -> "generic " ^ base
    | TFunc _ -> "callable"
    | TVoid -> "void"
  in
  let reduction_op_name = function
    | ReduceAdd -> "add"
    | ReduceMul -> "mul"
    | ReduceMax -> "max"
    | ReduceMin -> "min"
    | ReduceIand -> "iand"
    | ReduceIor -> "ior"
    | ReduceIeor -> "ieor"
    | ReduceAnd -> "and"
    | ReduceOr -> "or"
    | ReduceEqv -> "eqv"
    | ReduceNeqv -> "neqv"
  in
  let reduction_type_ok op = function
    | TInt ->
      (match op with
       | ReduceAdd | ReduceMul | ReduceMax | ReduceMin
       | ReduceIand | ReduceIor | ReduceIeor -> true
       | ReduceAnd | ReduceOr | ReduceEqv | ReduceNeqv -> false)
    | TFloat ->
      (match op with
       | ReduceAdd | ReduceMul | ReduceMax | ReduceMin -> true
       | ReduceIand | ReduceIor | ReduceIeor
       | ReduceAnd | ReduceOr | ReduceEqv | ReduceNeqv -> false)
    | TBool ->
      (match op with
       | ReduceAnd | ReduceOr | ReduceEqv | ReduceNeqv -> true
       | ReduceAdd | ReduceMul | ReduceMax | ReduceMin
       | ReduceIand | ReduceIor | ReduceIeor -> false)
    | TString | TArray _ | TCoarray _ | TStruct _ | TGeneric _ | TFunc _ | TVoid -> false
  in
  let global_env =
    List.fold_left (fun env decl ->
      match decl with
      | GlobalVarDecl (name, typ, _) -> add_binding env name typ
      | Import _ | StructDef _ | FuncDef _ -> env
    ) StringMap.empty program
  in
  let rec check_stmt func_name env = function
    | If { body; elifs; else_body; _ } ->
      List.iter (check_stmt func_name env) body;
      List.iter (fun (_, elif_body) -> List.iter (check_stmt func_name env) elif_body) elifs;
      List.iter (check_stmt func_name env) else_body
    | For { var; for_body; parallel; omp; local_vars; local_init_vars; reduce_specs; _ } ->
      let has_do_concurrent_clauses =
        local_vars <> [] || local_init_vars <> [] || reduce_specs <> []
      in
      if has_do_concurrent_clauses && not parallel && not omp then
        errors := (Printf.sprintf
          "Loop over %s uses @local/@local_init/@reduce without @par or @omp" var) :: !errors;
      let seen = ref StringSet.empty in
      let check_clause_var clause_name name =
        if name = var then
          errors := (Printf.sprintf
            "%s cannot list the loop variable %s" clause_name name) :: !errors;
        if StringSet.mem name !seen then
          errors := (Printf.sprintf
            "Variable %s appears more than once in do concurrent clauses for loop %s"
            name var) :: !errors
        else
          seen := StringSet.add name !seen;
        match StringMap.find_opt name env with
        | None ->
          errors := (Printf.sprintf
            "%s references unknown variable %s in %s" clause_name name func_name) :: !errors;
          None
        | Some typ ->
          if type_contains_coarray typ then
            errors := (Printf.sprintf
              "%s cannot use coarray variable %s" clause_name name) :: !errors;
          if type_contains_callable typ then
            errors := (Printf.sprintf
              "%s cannot use callable variable %s" clause_name name) :: !errors;
          Some typ
      in
      List.iter (fun name ->
        match check_clause_var "@local" name with
        | Some (TArray _ | TCoarray _ as typ) ->
          errors := (Printf.sprintf
            "@local currently supports scalar variables only, but %s has type %s"
            name (type_name typ)) :: !errors
        | _ -> ()
      ) local_vars;
      List.iter (fun name ->
        match check_clause_var "@local_init" name with
        | Some (TArray _ | TCoarray _ as typ) ->
          errors := (Printf.sprintf
            "@local_init currently supports scalar variables only, but %s has type %s"
            name (type_name typ)) :: !errors
        | _ -> ()
      ) local_init_vars;
      List.iter (fun spec ->
        List.iter (fun name ->
          match check_clause_var
            (Printf.sprintf "@reduce(%s)" (reduction_op_name spec.reduce_op)) name with
          | Some typ when not (reduction_type_ok spec.reduce_op typ) ->
            errors := (Printf.sprintf
              "@reduce(%s) requires a compatible scalar variable, but %s has type %s"
              (reduction_op_name spec.reduce_op) name (type_name typ)) :: !errors
          | _ -> ()
        ) spec.reduce_vars
      ) reduce_specs;
      List.iter (check_stmt func_name env) for_body
    | While (_, body) ->
      List.iter (check_stmt func_name env) body
    | Assign _ | VarDecl _ | AugAssign _ | Return _ | Break
    | ExprStmt _ | Print _ | SyncAll | Allocate _ | Pass ->
      ()
  in
  List.iter (function
    | FuncDef { func_name; params; body; _ } ->
      let fn_env =
        List.fold_left (fun env param ->
          add_binding env param.param_name param.param_type
        ) global_env params
      in
      let fn_env = List.fold_left collect_stmt_bindings fn_env body in
      List.iter (check_stmt func_name fn_env) body
    | Import _ | StructDef _ | GlobalVarDecl _ -> ()
  ) program;
  !errors

(* Check @gpu loop-specific restrictions. *)
let validate_gpu_loops program =
  let errors = ref [] in
  let add_binding env name typ =
    if StringMap.mem name env then env else StringMap.add name typ env
  in
  let rec collect_stmt_bindings env = function
    | VarDecl (name, typ, _) ->
      add_binding env name typ
    | If { body; elifs; else_body; _ } ->
      let env = List.fold_left collect_stmt_bindings env body in
      let env =
        List.fold_left (fun acc (_, elif_body) ->
          List.fold_left collect_stmt_bindings acc elif_body
        ) env elifs
      in
      List.fold_left collect_stmt_bindings env else_body
    | For { var; for_body; _ } ->
      let env = add_binding env var TInt in
      List.fold_left collect_stmt_bindings env for_body
    | While (_, body) ->
      List.fold_left collect_stmt_bindings env body
    | Assign _ | AugAssign _ | Return _ | Break | ExprStmt _ | Print _
    | SyncAll | Allocate _ | Pass ->
      env
  in
  let global_env =
    List.fold_left (fun env decl ->
      match decl with
      | GlobalVarDecl (name, typ, _) -> add_binding env name typ
      | Import _ | StructDef _ | FuncDef _ -> env
    ) StringMap.empty program
  in
  let rec expr_uses_coarray = function
    | CoarrayIndex (target_e, idxs) ->
      let _ = expr_uses_coarray target_e in
      let _ = List.exists expr_uses_coarray idxs in
      true
    | Call (("this_image" | "num_images"
           | "co_sum" | "co_min" | "co_max" | "co_broadcast" | "co_reduce"), args) ->
      let _ = List.exists expr_uses_coarray args in
      true
    | Call (_, args) -> List.exists expr_uses_coarray args
    | BinOp (_, l, r) -> expr_uses_coarray l || expr_uses_coarray r
    | UnaryOp (_, e) -> expr_uses_coarray e
    | Index (e, subs) ->
      expr_uses_coarray e || List.exists subscript_uses_coarray subs
    | FieldAccess (e, _) -> expr_uses_coarray e
    | ArrayLit elems -> List.exists expr_uses_coarray elems
    | RangeExpr (start_e, stop_e, step_e) ->
      expr_uses_coarray start_e ||
      expr_uses_coarray stop_e ||
      (match step_e with Some e -> expr_uses_coarray e | None -> false)
    | FString parts -> List.exists (fun p -> match p with FStrExpr (e, _) -> expr_uses_coarray e | FStrLit _ -> false) parts
    | IntLit _ | FloatLit _ | BoolLit _ | StringLit _ | Var _ -> false
  and subscript_uses_coarray = function
    | IndexSubscript e -> expr_uses_coarray e
    | SliceSubscript (start_e, stop_e, step_e) ->
      (match start_e with Some e -> expr_uses_coarray e | None -> false) ||
      (match stop_e with Some e -> expr_uses_coarray e | None -> false) ||
      (match step_e with Some e -> expr_uses_coarray e | None -> false)
  and stmt_uses_coarray = function
    | Assign (target, value) ->
      expr_uses_coarray target || expr_uses_coarray value
    | VarDecl (_, _, Some e) -> expr_uses_coarray e
    | VarDecl (_, _, None) -> false
    | AugAssign (_, target, value) ->
      expr_uses_coarray target || expr_uses_coarray value
    | Return (Some e) -> expr_uses_coarray e
    | Return None -> false
    | Break -> false
    | If { cond; body; elifs; else_body } ->
      expr_uses_coarray cond ||
      List.exists stmt_uses_coarray body ||
      List.exists (fun (elif_cond, elif_body) ->
        expr_uses_coarray elif_cond || List.exists stmt_uses_coarray elif_body
      ) elifs ||
      List.exists stmt_uses_coarray else_body
    | For { start_expr; end_expr; step_expr; for_body; _ } ->
      expr_uses_coarray start_expr ||
      expr_uses_coarray end_expr ||
      (match step_expr with Some e -> expr_uses_coarray e | None -> false) ||
      List.exists stmt_uses_coarray for_body
    | While (cond, body) ->
      expr_uses_coarray cond || List.exists stmt_uses_coarray body
    | ExprStmt e -> expr_uses_coarray e
    | Print args -> List.exists expr_uses_coarray args
    | SyncAll -> true
    | Allocate (_, dims) ->
      let _ = List.exists expr_uses_coarray dims in
      true
    | Pass -> false
  in
  let rec expr_array_rank env = function
    | Var name ->
      (match StringMap.find_opt name env with
       | Some (TArray (_, dims)) -> Some (List.length dims)
       | Some (TCoarray (TArray (_, dims), _)) -> Some (List.length dims)
       | _ -> None)
    | FieldAccess _ -> None
    | Index (base, _) -> expr_array_rank env base
    | CoarrayIndex (base, _) -> expr_array_rank env base
    | FString _ -> None
    | IntLit _ | FloatLit _ | BoolLit _ | StringLit _
    | BinOp _ | UnaryOp _ | Call _ | ArrayLit _ | RangeExpr _ -> None
  in
  let rec check_expr env func_name in_gpu = function
    | FString parts -> List.iter (fun p -> match p with FStrExpr (e, _) -> check_expr env func_name in_gpu e | FStrLit _ -> ()) parts
    | IntLit _ | FloatLit _ | BoolLit _ | StringLit _ | Var _ -> ()
    | BinOp (_, l, r) ->
      check_expr env func_name in_gpu l;
      check_expr env func_name in_gpu r
    | UnaryOp (_, e) -> check_expr env func_name in_gpu e
    | Call (_, args) -> List.iter (check_expr env func_name in_gpu) args
    | Index (base, subs) ->
      check_expr env func_name in_gpu base;
      (match in_gpu, expr_array_rank env base with
       | true, Some rank when rank > 2 ->
         errors := (Printf.sprintf
           "@gpu loop in %s references an array with rank %d; only rank 1-2 arrays are supported"
           func_name rank) :: !errors
       | _ -> ());
      List.iter (check_subscript env func_name in_gpu) subs
    | CoarrayIndex (e, idxs) ->
      check_expr env func_name in_gpu e;
      List.iter (check_expr env func_name in_gpu) idxs
    | FieldAccess (e, _) -> check_expr env func_name in_gpu e
    | ArrayLit elems -> List.iter (check_expr env func_name in_gpu) elems
    | RangeExpr (start_e, stop_e, step_e) ->
      check_expr env func_name in_gpu start_e;
      check_expr env func_name in_gpu stop_e;
      (match step_e with Some e -> check_expr env func_name in_gpu e | None -> ())
  and check_subscript env func_name in_gpu = function
    | IndexSubscript e -> check_expr env func_name in_gpu e
    | SliceSubscript (start_e, stop_e, step_e) ->
      (match start_e with Some e -> check_expr env func_name in_gpu e | None -> ());
      (match stop_e with Some e -> check_expr env func_name in_gpu e | None -> ());
      (match step_e with Some e -> check_expr env func_name in_gpu e | None -> ())
  and check_stmt env func_name in_gpu = function
    | Assign (target, value) ->
      check_expr env func_name in_gpu target;
      check_expr env func_name in_gpu value
    | VarDecl (_, _, Some e) -> check_expr env func_name in_gpu e
    | VarDecl (_, _, None) -> ()
    | AugAssign (_, target, value) ->
      check_expr env func_name in_gpu target;
      check_expr env func_name in_gpu value
    | Return (Some e) -> check_expr env func_name in_gpu e
    | Return None -> ()
    | Break -> ()
    | If { cond; body; elifs; else_body } ->
      check_expr env func_name in_gpu cond;
      List.iter (check_stmt env func_name in_gpu) body;
      List.iter (fun (elif_cond, elif_body) ->
        check_expr env func_name in_gpu elif_cond;
        List.iter (check_stmt env func_name in_gpu) elif_body
      ) elifs;
      List.iter (check_stmt env func_name in_gpu) else_body
    | For { var; start_expr; end_expr; step_expr; for_body; parallel; gpu; _ } ->
      let loop_env = add_binding env var TInt in
      let loop_in_gpu = in_gpu || gpu in
      check_expr loop_env func_name loop_in_gpu start_expr;
      check_expr loop_env func_name loop_in_gpu end_expr;
      (match step_expr with Some e -> check_expr loop_env func_name loop_in_gpu e | None -> ());
      if gpu then begin
        if not parallel then
          errors := (Printf.sprintf "@gpu loop in %s must also be marked @par" func_name) :: !errors;
        if List.exists stmt_uses_coarray for_body then
          errors := (Printf.sprintf "Coarray operations are not allowed inside @gpu loops in %s" func_name) :: !errors;
      end;
      List.iter (check_stmt loop_env func_name loop_in_gpu) for_body
    | While (cond, body) ->
      check_expr env func_name in_gpu cond;
      List.iter (check_stmt env func_name in_gpu) body
    | ExprStmt e -> check_expr env func_name in_gpu e
    | Print args -> List.iter (check_expr env func_name in_gpu) args
    | SyncAll -> ()
    | Allocate (_, dims) -> List.iter (check_expr env func_name in_gpu) dims
    | Pass -> ()
  in
  List.iter (function
    | FuncDef { func_name; params; body; _ } ->
      let fn_env =
        List.fold_left (fun env param ->
          add_binding env param.param_name param.param_type
        ) global_env params
      in
      let fn_env = List.fold_left collect_stmt_bindings fn_env body in
      List.iter (check_stmt fn_env func_name false) body
    | Import _ | StructDef _ | GlobalVarDecl _ -> ()
  ) program;
  !errors

(* Check loop-exit control flow. *)
let validate_break_usage program =
  let errors = ref [] in
  let rec check_stmt in_loop in_parallel in_gpu = function
    | Break ->
      if not in_loop then
        errors := "break can only be used inside a loop" :: !errors;
      if in_parallel then
        errors := "break is not allowed inside @par or @omp loops" :: !errors;
      if in_gpu then
        errors := "break is not allowed inside @gpu loops" :: !errors
    | If { body; elifs; else_body; _ } ->
      List.iter (check_stmt in_loop in_parallel in_gpu) body;
      List.iter (fun (_, elif_body) ->
        List.iter (check_stmt in_loop in_parallel in_gpu) elif_body
      ) elifs;
      List.iter (check_stmt in_loop in_parallel in_gpu) else_body
    | For { for_body; parallel; gpu; omp; _ } ->
      let loop_parallel = in_parallel || parallel || omp in
      let loop_gpu = in_gpu || gpu in
      List.iter (check_stmt true loop_parallel loop_gpu) for_body
    | While (_, body) ->
      List.iter (check_stmt true in_parallel in_gpu) body
    | Assign _ | VarDecl _ | AugAssign _ | Return _
    | ExprStmt _ | Print _ | SyncAll | Allocate _ | Pass ->
      ()
  in
  List.iter (function
    | FuncDef { body; _ } -> List.iter (check_stmt false false false) body
    | Import _ | StructDef _ | GlobalVarDecl _ -> ()
  ) program;
  !errors

(* Best-effort race-condition check for @omp loops (which lower to an OpenMP
   parallel do). The transpiler auto-privatizes every scalar assigned in the
   loop body, which is safe only when each scalar is written before it is read
   within an iteration. When a scalar is instead read before it is written, it
   carries a value across iterations: either a reduction (which needs @reduce)
   or a sequential dependence that is not parallel-safe. Auto-privatization
   (firstprivate) silently hides both, so they are reported as errors; annotate
   with @reduce or @local_init to assert the intent. Returns error strings; the
   caller adds them to the fatal error list. Scoped to @omp because OpenMP has
   no language-level loop-carried diagnostics, unlike do concurrent. *)
let validate_omp_loop_safety program =
  let issues = ref [] in
  (* Does `name` appear as a read (any Var occurrence) anywhere in `e`? *)
  let rec expr_reads name = function
    | Var n -> n = name
    | IntLit _ | FloatLit _ | BoolLit _ | StringLit _ -> false
    | BinOp (_, l, r) -> expr_reads name l || expr_reads name r
    | UnaryOp (_, e) -> expr_reads name e
    | Call (_, args) -> List.exists (expr_reads name) args
    | Index (e, subs) -> expr_reads name e || List.exists (sub_reads name) subs
    | CoarrayIndex (e, idxs) -> expr_reads name e || List.exists (expr_reads name) idxs
    | FieldAccess (e, _) -> expr_reads name e
    | ArrayLit elems -> List.exists (expr_reads name) elems
    | RangeExpr (a, b, c) ->
      expr_reads name a || expr_reads name b ||
      (match c with Some e -> expr_reads name e | None -> false)
    | FString parts ->
      List.exists (function FStrExpr (e, _) -> expr_reads name e | FStrLit _ -> false) parts
  and sub_reads name = function
    | IndexSubscript e -> expr_reads name e
    | SliceSubscript (a, b, c) ->
      (match a with Some e -> expr_reads name e | None -> false) ||
      (match b with Some e -> expr_reads name e | None -> false) ||
      (match c with Some e -> expr_reads name e | None -> false)
  in
  let read_any name es = List.exists (expr_reads name) es in
  (* First reference to `name` in execution order: `Rd, `Wr, or `Absent. A
     whole-variable assignment with no self-read is the only `Wr; a conditional
     or inner loop is descended into. Branches combine as `Rd if any branch
     reads first, else `Wr if any writes. *)
  let rec first_ref name stmts =
    match stmts with
    | [] -> `Absent
    | s :: rest -> (match stmt_ref name s with `Absent -> first_ref name rest | r -> r)
  and stmt_ref name = function
    | Assign (Var n, rhs) ->
      if expr_reads name rhs then `Rd else if n = name then `Wr else `Absent
    | Assign (target, rhs) ->
      if expr_reads name target || expr_reads name rhs then `Rd else `Absent
    | AugAssign (_, Var n, rhs) ->
      if n = name || expr_reads name rhs then `Rd else `Absent
    | AugAssign (_, target, rhs) ->
      if expr_reads name target || expr_reads name rhs then `Rd else `Absent
    | VarDecl (n, _, Some e) ->
      if expr_reads name e then `Rd else if n = name then `Wr else `Absent
    | VarDecl (n, _, None) -> if n = name then `Wr else `Absent
    | Return (Some e) | ExprStmt e -> if expr_reads name e then `Rd else `Absent
    | Print args -> if read_any name args then `Rd else `Absent
    | Allocate (_, dims) -> if read_any name dims then `Rd else `Absent
    | If { cond; body; elifs; else_body } ->
      if expr_reads name cond then `Rd
      else begin
        let branches =
          [first_ref name body]
          @ List.map (fun (c, b) -> if expr_reads name c then `Rd else first_ref name b) elifs
          @ [first_ref name else_body]
        in
        if List.mem `Rd branches then `Rd
        else if List.mem `Wr branches then `Wr
        else `Absent
      end
    | For { start_expr; end_expr; step_expr; for_body; _ } ->
      if expr_reads name start_expr || expr_reads name end_expr
         || (match step_expr with Some e -> expr_reads name e | None -> false)
      then `Rd else first_ref name for_body
    | While (cond, body) ->
      if expr_reads name cond then `Rd else first_ref name body
    | Return None | Break | SyncAll | Pass -> `Absent
  in
  (* Names assigned as a whole variable anywhere in the body. *)
  let rec whole_assigned stmts =
    List.concat_map (function
      | Assign (Var n, _) -> [n]
      | AugAssign (_, Var n, _) -> [n]
      | VarDecl (n, _, _) -> [n]
      | If { body; elifs; else_body; _ } ->
        whole_assigned body
        @ List.concat_map (fun (_, b) -> whole_assigned b) elifs
        @ whole_assigned else_body
      | For { for_body; _ } -> whole_assigned for_body
      | While (_, body) -> whole_assigned body
      | _ -> []) stmts
  in
  let add_binding env name typ =
    if StringMap.mem name env then env else StringMap.add name typ env in
  let rec collect_bindings env = function
    | VarDecl (name, typ, _) -> add_binding env name typ
    | If { body; elifs; else_body; _ } ->
      let env = List.fold_left collect_bindings env body in
      let env = List.fold_left (fun acc (_, b) -> List.fold_left collect_bindings acc b) env elifs in
      List.fold_left collect_bindings env else_body
    | For { var; for_body; _ } ->
      List.fold_left collect_bindings (add_binding env var TInt) for_body
    | While (_, body) -> List.fold_left collect_bindings env body
    | _ -> env
  in
  let global_env =
    List.fold_left (fun env -> function
      | GlobalVarDecl (name, typ, _) -> add_binding env name typ
      | _ -> env) StringMap.empty program
  in
  let is_scalar env name =
    match StringMap.find_opt name env with
    | Some (TInt | TFloat | TBool | TString) -> true
    | _ -> false
  in
  (* All Var names appearing in an expression / subscript (for deciding whether
     a differing index position varies with an inner sequential loop only). *)
  let rec vars_of_expr = function
    | Var n -> [n]
    | IntLit _ | FloatLit _ | BoolLit _ | StringLit _ -> []
    | BinOp (_, l, r) -> vars_of_expr l @ vars_of_expr r
    | UnaryOp (_, e) -> vars_of_expr e
    | Call (_, args) -> List.concat_map vars_of_expr args
    | Index (e, subs) -> vars_of_expr e @ List.concat_map vars_of_sub subs
    | CoarrayIndex (e, idxs) -> vars_of_expr e @ List.concat_map vars_of_expr idxs
    | FieldAccess (e, _) -> vars_of_expr e
    | ArrayLit elems -> List.concat_map vars_of_expr elems
    | RangeExpr (a, b, c) ->
      vars_of_expr a @ vars_of_expr b @ (match c with Some e -> vars_of_expr e | None -> [])
    | FString parts ->
      List.concat_map (function FStrExpr (e, _) -> vars_of_expr e | FStrLit _ -> []) parts
  and vars_of_sub = function
    | IndexSubscript e -> vars_of_expr e
    | SliceSubscript (a, b, c) ->
      (match a with Some e -> vars_of_expr e | None -> []) @
      (match b with Some e -> vars_of_expr e | None -> []) @
      (match c with Some e -> vars_of_expr e | None -> [])
  in
  (* Dotted base name of an array reference, e.g. "out" or "eq.diag". *)
  let rec base_key_of = function
    | Var n -> Some n
    | FieldAccess (e, f) -> (match base_key_of e with Some s -> Some (s ^ "." ^ f) | None -> None)
    | _ -> None
  in
  (* Element reads (base, subscript list) reachable inside an expression. *)
  let rec reads_in_expr = function
    | Index (b, subs) ->
      (match base_key_of b with Some k -> [(k, subs)] | None -> [])
      @ reads_in_expr b @ reads_in_subs subs
    | Var _ | IntLit _ | FloatLit _ | BoolLit _ | StringLit _ -> []
    | BinOp (_, l, r) -> reads_in_expr l @ reads_in_expr r
    | UnaryOp (_, e) -> reads_in_expr e
    | Call (_, args) -> List.concat_map reads_in_expr args
    | CoarrayIndex (e, idxs) -> reads_in_expr e @ List.concat_map reads_in_expr idxs
    | FieldAccess (e, _) -> reads_in_expr e
    | ArrayLit elems -> List.concat_map reads_in_expr elems
    | RangeExpr (a, b, c) ->
      reads_in_expr a @ reads_in_expr b @ (match c with Some e -> reads_in_expr e | None -> [])
    | FString parts ->
      List.concat_map (function FStrExpr (e, _) -> reads_in_expr e | FStrLit _ -> []) parts
  and reads_in_subs subs =
    List.concat_map (function
      | IndexSubscript e -> reads_in_expr e
      | SliceSubscript (a, b, c) ->
        (match a with Some e -> reads_in_expr e | None -> []) @
        (match b with Some e -> reads_in_expr e | None -> []) @
        (match c with Some e -> reads_in_expr e | None -> [])) subs
  in
  (* Element write (and the reads from its own index exprs) for an lvalue. *)
  let lvalue_access = function
    | Index (b, subs) ->
      (match base_key_of b with
       | Some k -> ([(k, subs)], reads_in_subs subs)
       | None -> ([], reads_in_subs subs))
    | _ -> ([], [])
  in
  (* (writes, reads) of array elements over a statement list. An augmented
     assignment target counts as both a write and a read. *)
  let rec collect_accesses stmts =
    List.fold_left (fun (ws, rs) s ->
      let (w, r) = stmt_accesses s in (ws @ w, rs @ r)) ([], []) stmts
  and stmt_accesses = function
    | Assign (target, rhs) ->
      let (tw, tr) = lvalue_access target in (tw, tr @ reads_in_expr rhs)
    | AugAssign (_, target, rhs) ->
      let (tw, tr) = lvalue_access target in (tw, tw @ tr @ reads_in_expr rhs)
    | VarDecl (_, _, Some e) -> ([], reads_in_expr e)
    | VarDecl (_, _, None) -> ([], [])
    | Return (Some e) | ExprStmt e -> ([], reads_in_expr e)
    | Print args -> ([], List.concat_map reads_in_expr args)
    | Allocate (_, dims) -> ([], List.concat_map reads_in_expr dims)
    | If { cond; body; elifs; else_body } ->
      let (wb, rb) = collect_accesses body in
      let (we, re) =
        List.fold_left (fun (w, r) (c, b) ->
          let (w2, r2) = collect_accesses b in (w @ w2, r @ reads_in_expr c @ r2)) ([], []) elifs in
      let (wel, rel) = collect_accesses else_body in
      (wb @ we @ wel, reads_in_expr cond @ rb @ re @ rel)
    | For { start_expr; end_expr; step_expr; for_body; _ } ->
      let (w, r) = collect_accesses for_body in
      (w, r @ reads_in_expr start_expr @ reads_in_expr end_expr
          @ (match step_expr with Some e -> reads_in_expr e | None -> []))
    | While (cond, body) -> let (w, r) = collect_accesses body in (w, reads_in_expr cond @ r)
    | Return None | Break | SyncAll | Pass -> ([], [])
  in
  (* Variables of loops nested inside the body (sequential within an iteration). *)
  let rec inner_loop_vars stmts =
    List.concat_map (function
      | For { var; for_body; _ } -> var :: inner_loop_vars for_body
      | If { body; elifs; else_body; _ } ->
        inner_loop_vars body
        @ List.concat_map (fun (_, b) -> inner_loop_vars b) elifs
        @ inner_loop_vars else_body
      | While (_, body) -> inner_loop_vars body
      | _ -> []) stmts
  in
  (* Array base names that are written at one index and read at a different one,
     where the differing index position varies with something other than an
     inner sequential loop variable (so the dependence crosses parallel
     iterations). *)
  let conflicting_arrays writes reads inner =
    let written_keys = List.sort_uniq String.compare (List.map fst writes) in
    List.filter (fun key ->
      let wt = List.filter_map (fun (k, s) -> if k = key then Some s else None) writes in
      let rt = List.filter_map (fun (k, s) -> if k = key then Some s else None) reads in
      List.exists (fun r ->
        (not (List.mem r wt)) &&
        List.exists (fun w ->
          List.length w = List.length r &&
          (let diffs = List.filter (fun (a, b) -> a <> b) (List.combine w r) in
           diffs <> [] &&
           List.exists (fun (_, rb) ->
             List.exists (fun v -> not (List.mem v inner)) (vars_of_sub rb)) diffs)
        ) wt
      ) rt
    ) written_keys
  in
  let check_omp_loop func_name env loop =
    let reduce_vars = List.concat_map (fun s -> s.reduce_vars) loop.reduce_specs in
    let explicit = loop.var :: loop.local_vars @ loop.local_init_vars @ reduce_vars in
    (* Check 1: scalar read before written (likely reduction / sequential dep). *)
    whole_assigned loop.for_body
    |> List.sort_uniq String.compare
    |> List.filter (fun n -> (not (List.mem n explicit)) && is_scalar env n)
    |> List.iter (fun n ->
         if first_ref n loop.for_body = `Rd then
           issues := (Printf.sprintf
             "in %s, @omp loop over %s reads scalar '%s' before assigning it; it is auto-privatized (firstprivate). If this is a reduction add @reduce(<op>: %s), otherwise the iterations are not independent and the loop is not parallel-safe."
             func_name loop.var n n) :: !issues);
    (* Check 2: array written and read at differing parallel-iteration indices. *)
    let (writes, reads) = collect_accesses loop.for_body in
    let inner = inner_loop_vars loop.for_body in
    conflicting_arrays writes reads inner
    |> List.iter (fun key ->
         issues := (Printf.sprintf
           "in %s, @omp loop over %s writes array '%s' and also reads it at a different index; if an iteration reads a value another iteration writes (e.g. a stencil reading its own output) the loop is not parallel-safe."
           func_name loop.var key) :: !issues)
  in
  let rec walk func_name env stmts =
    List.iter (fun s ->
      match s with
      | For ({ omp; _ } as loop) ->
        if omp then check_omp_loop func_name env loop;
        walk func_name env loop.for_body
      | If { body; elifs; else_body; _ } ->
        walk func_name env body;
        List.iter (fun (_, b) -> walk func_name env b) elifs;
        walk func_name env else_body
      | While (_, body) -> walk func_name env body
      | _ -> ()) stmts
  in
  List.iter (function
    | FuncDef { func_name; params; body; _ } ->
      let env =
        List.fold_left (fun e p -> add_binding e p.param_name p.param_type) global_env params in
      let env = List.fold_left collect_bindings env body in
      walk func_name env body
    | Import _ | StructDef _ | GlobalVarDecl _ -> ()
  ) program;
  List.rev !issues

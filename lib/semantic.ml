open Ast

type error = {
  msg: string;
  (* Could add location info later *)
}

exception SemanticError of string

(* ---- Recursion Detection ---- *)
(* Build a call graph and check for cycles *)

module StringSet = Set.Make(String)
module StringMap = Map.Make(String)

let try_const_int = function
  | IntLit n -> Some n
  | UnaryOp (Neg, IntLit n) -> Some (-n)
  | _ -> None

let is_deferred_dim = function
  | DeferredDim -> true
  | FixedDim _ -> false

let is_coarray_type = function
  | TCoarray _ -> true
  | _ -> false

let rec type_contains_coarray = function
  | TCoarray _ -> true
  | TArray (elem_t, _) -> type_contains_coarray elem_t
  | TFunc (param_types, return_type) ->
    List.exists type_contains_coarray param_types || type_contains_coarray return_type
  | _ -> false

let rec type_contains_callable = function
  | TFunc _ -> true
  | TArray (elem_t, _) -> type_contains_callable elem_t
  | TCoarray (elem_t, _) -> type_contains_callable elem_t
  | _ -> false

let is_two_dim_float_array = function
  | TArray (TFloat, [DeferredDim; DeferredDim]) -> true
  | _ -> false

let is_one_dim_float_array = function
  | TArray (TFloat, [DeferredDim]) -> true
  | _ -> false

let is_lapack_qr_stub = function
  | { func_name = "qr"; params; return_type = TVoid; body = [Pass] } ->
    List.length params = 3 &&
    List.for_all (fun p -> is_two_dim_float_array p.param_type) params
  | _ -> false

let is_lapack_svd_stub = function
  | { func_name = "svd"; params; return_type = TVoid; body = [Pass] } ->
    List.length params = 4 &&
    (match params with
     | [a_param; u_param; s_param; vt_param] ->
       is_two_dim_float_array a_param.param_type &&
       is_two_dim_float_array u_param.param_type &&
       is_one_dim_float_array s_param.param_type &&
       is_two_dim_float_array vt_param.param_type
     | _ -> false)
  | _ -> false

let is_lapack_solve_stub = function
  | { func_name = "solve"; params; return_type = TVoid; body = [Pass] } ->
    List.length params = 3 &&
    (match params with
     | [a_param; b_param; x_param] ->
       is_two_dim_float_array a_param.param_type &&
       is_one_dim_float_array b_param.param_type &&
       is_one_dim_float_array x_param.param_type
     | _ -> false)
  | _ -> false

(* Collect all function calls within a list of statements *)
let rec calls_in_stmts stmts =
  List.fold_left (fun acc s -> StringSet.union acc (calls_in_stmt s)) StringSet.empty stmts

and calls_in_stmt = function
  | Assign (_, e) -> calls_in_expr e
  | VarDecl (_, _, Some e) -> calls_in_expr e
  | VarDecl (_, _, None) -> StringSet.empty
  | AugAssign (_, _, e) -> calls_in_expr e
  | Return (Some e) -> calls_in_expr e
  | Return None -> StringSet.empty
  | If { cond; body; elifs; else_body } ->
    let s = calls_in_expr cond in
    let s = StringSet.union s (calls_in_stmts body) in
    let s = List.fold_left (fun acc (c, b) ->
      StringSet.union acc (StringSet.union (calls_in_expr c) (calls_in_stmts b))
    ) s elifs in
    StringSet.union s (calls_in_stmts else_body)
  | For { start_expr; end_expr; step_expr; for_body; _ } ->
    let s = calls_in_expr start_expr in
    let s = StringSet.union s (calls_in_expr end_expr) in
    let s = (match step_expr with Some e -> StringSet.union s (calls_in_expr e) | None -> s) in
    StringSet.union s (calls_in_stmts for_body)
  | While (cond, body) ->
    StringSet.union (calls_in_expr cond) (calls_in_stmts body)
  | ExprStmt e -> calls_in_expr e
  | Print args -> List.fold_left (fun acc e -> StringSet.union acc (calls_in_expr e)) StringSet.empty args
  | SyncAll -> StringSet.empty
  | Allocate (_, dims) ->
    List.fold_left (fun acc e -> StringSet.union acc (calls_in_expr e)) StringSet.empty dims
  | Pass -> StringSet.empty

and calls_in_expr = function
  | IntLit _ | FloatLit _ | BoolLit _ | StringLit _ | Var _ -> StringSet.empty
  | BinOp (_, l, r) -> StringSet.union (calls_in_expr l) (calls_in_expr r)
  | UnaryOp (_, e) -> calls_in_expr e
  | Call (name, args) ->
    let s = StringSet.singleton name in
    List.fold_left (fun acc e -> StringSet.union acc (calls_in_expr e)) s args
  | Index (e, subs) ->
    List.fold_left (fun acc sub -> StringSet.union acc (calls_in_subscript sub))
      (calls_in_expr e) subs
  | CoarrayIndex (e, idxs) ->
    List.fold_left (fun acc i -> StringSet.union acc (calls_in_expr i))
      (calls_in_expr e) idxs
  | FieldAccess (e, _) -> calls_in_expr e
  | ArrayLit elems ->
    List.fold_left (fun acc e -> StringSet.union acc (calls_in_expr e)) StringSet.empty elems
  | RangeExpr (a, b, c) ->
    let s = StringSet.union (calls_in_expr a) (calls_in_expr b) in
    (match c with Some e -> StringSet.union s (calls_in_expr e) | None -> s)

and calls_in_subscript = function
  | IndexSubscript e -> calls_in_expr e
  | SliceSubscript (start_e, stop_e, step_e) ->
    (* Slice bounds can contain arbitrary expressions and calls. *)
    let s = match start_e with Some e -> calls_in_expr e | None -> StringSet.empty in
    let s = match stop_e with Some e -> StringSet.union s (calls_in_expr e) | None -> s in
    (match step_e with Some e -> StringSet.union s (calls_in_expr e) | None -> s)

let build_call_graph (program : program) : StringSet.t StringMap.t =
  List.fold_left (fun graph decl ->
    match decl with
    | FuncDef { func_name; body; _ } ->
      StringMap.add func_name (calls_in_stmts body) graph
    | _ -> graph
  ) StringMap.empty program

(* DFS cycle detection *)
let detect_recursion call_graph =
  let errors = ref [] in
  let visited = Hashtbl.create 16 in
  let in_stack = Hashtbl.create 16 in
  let rec dfs node path =
    if Hashtbl.mem in_stack node then begin
      let cycle = node :: (List.rev path) in
      let cycle_str = String.concat " -> " cycle in
      errors := (Printf.sprintf "Recursion detected: %s" cycle_str) :: !errors
    end else if not (Hashtbl.mem visited node) then begin
      Hashtbl.add visited node true;
      Hashtbl.add in_stack node true;
      (match StringMap.find_opt node call_graph with
       | Some callees ->
         StringSet.iter (fun callee ->
           if StringMap.mem callee call_graph then  (* only check user-defined functions *)
             dfs callee (node :: path)
         ) callees
       | None -> ());
      Hashtbl.remove in_stack node
    end
  in
  StringMap.iter (fun name _ -> dfs name []) call_graph;
  !errors

(* ---- Struct Validation ---- *)
(* Check that struct fields reference valid types *)
let validate_structs program =
  let struct_names = List.fold_left (fun acc d ->
    match d with StructDef (name, _) -> StringSet.add name acc | _ -> acc
  ) StringSet.empty program in
  let errors = ref [] in
  let validate_array_dims dims =
    let has_fixed = List.exists (function FixedDim _ -> true | DeferredDim -> false) dims in
    let has_deferred = List.exists (function FixedDim _ -> false | DeferredDim -> true) dims in
    if has_fixed && has_deferred then
      errors := "Array types cannot mix fixed extents and deferred ':' extents" :: !errors
  in
  let rec check_type = function
    | TStruct name ->
      if not (StringSet.mem name struct_names) then
        errors := (Printf.sprintf "Unknown struct type: %s" name) :: !errors
    | TFunc (param_types, return_type) ->
      List.iter check_type param_types;
      check_type return_type
    | TArray (t, dims) ->
      validate_array_dims dims;
      check_type t
    | TCoarray (t, _) -> check_type t
    | _ -> ()
  in
  List.iter (fun d ->
    match d with
    | Import _ -> ()
    | StructDef (_, fields) ->
      List.iter (fun f -> check_type f.field_type) fields
    | FuncDef { params; return_type; _ } ->
      List.iter (fun p -> check_type p.param_type) params;
      check_type return_type
    | GlobalVarDecl (_, t, _) -> check_type t
  ) program;
  !errors

let validate_callable_support program =
  let errors = ref [] in
  let rec expr_mentions_name target = function
    | Var name -> name = target
    | BinOp (_, l, r) -> expr_mentions_name target l || expr_mentions_name target r
    | UnaryOp (_, e) -> expr_mentions_name target e
    | Call (_, args) -> List.exists (expr_mentions_name target) args
    | Index (e, subs) ->
      expr_mentions_name target e || List.exists (subscript_mentions_name target) subs
    | CoarrayIndex (e, idxs) ->
      expr_mentions_name target e || List.exists (expr_mentions_name target) idxs
    | FieldAccess (e, _) -> expr_mentions_name target e
    | ArrayLit elems -> List.exists (expr_mentions_name target) elems
    | RangeExpr (start_e, stop_e, step_e) ->
      expr_mentions_name target start_e ||
      expr_mentions_name target stop_e ||
      (match step_e with Some e -> expr_mentions_name target e | None -> false)
    | IntLit _ | FloatLit _ | BoolLit _ | StringLit _ -> false
  and subscript_mentions_name target = function
    | IndexSubscript e -> expr_mentions_name target e
    | SliceSubscript (start_e, stop_e, step_e) ->
      (match start_e with Some e -> expr_mentions_name target e | None -> false) ||
      (match stop_e with Some e -> expr_mentions_name target e | None -> false) ||
      (match step_e with Some e -> expr_mentions_name target e | None -> false)
  in
  let validate_callable_signature owner = function
    | TFunc (param_types, return_type) ->
      if List.exists type_contains_callable param_types || type_contains_callable return_type then
        errors := (Printf.sprintf "Callable type in %s cannot nest another callable type" owner) :: !errors;
      if List.exists type_contains_coarray param_types || type_contains_coarray return_type then
        errors := (Printf.sprintf "Callable type in %s cannot use coarray arguments or returns" owner) :: !errors
    | _ -> ()
  in
  let rec check_stmt func_name = function
    | VarDecl (name, typ, _) when type_contains_callable typ ->
      errors := (Printf.sprintf "Local variable %s in %s cannot have callable type yet" name func_name) :: !errors
    | If { body; elifs; else_body; _ } ->
      List.iter (check_stmt func_name) body;
      List.iter (fun (_, elif_body) -> List.iter (check_stmt func_name) elif_body) elifs;
      List.iter (check_stmt func_name) else_body
    | For { for_body; _ } -> List.iter (check_stmt func_name) for_body
    | While (_, body) -> List.iter (check_stmt func_name) body
    | _ -> ()
  in
  List.iter (function
    | Import _ -> ()
    | StructDef (struct_name, fields) ->
      List.iter (fun field ->
        if type_contains_callable field.field_type then
          errors := (Printf.sprintf "Struct %s field %s cannot have callable type yet"
            struct_name field.field_name) :: !errors
      ) fields
    | GlobalVarDecl (name, typ, _) ->
      if type_contains_callable typ then
        errors := (Printf.sprintf "Global variable %s cannot have callable type yet" name) :: !errors
    | FuncDef { func_name; params; return_type; body } ->
      if type_contains_callable return_type then
        errors := (Printf.sprintf "Function %s cannot return a callable type yet" func_name) :: !errors;
      let seen_default = ref false in
      let param_names = List.map (fun p -> p.param_name) params in
      List.iter (fun p ->
        validate_callable_signature
          (Printf.sprintf "parameter %s of %s" p.param_name func_name)
          p.param_type;
        (match p.default_value with
         | Some default_expr ->
           seen_default := true;
           if type_contains_callable p.param_type then
             errors := (Printf.sprintf "Callable parameter %s of %s cannot have a default value"
               p.param_name func_name) :: !errors;
           List.iter (fun param_name ->
             if expr_mentions_name param_name default_expr then
               errors := (Printf.sprintf
                 "Default value for parameter %s of %s cannot reference parameter %s"
                 p.param_name func_name param_name) :: !errors
           ) param_names
         | None ->
           if !seen_default then
             errors := (Printf.sprintf
               "Function %s has a required parameter %s after an optional parameter"
               func_name p.param_name) :: !errors)
      ) params;
      List.iter (check_stmt func_name) body
  ) program;
  !errors

let validate_function_calls program =
  let errors = ref [] in
  let user_functions = Hashtbl.create 32 in
  List.iter (function
    | FuncDef fd -> Hashtbl.replace user_functions fd.func_name fd
    | _ -> ()
  ) program;
  let check_callable_argument callback_env actual_expr expected_type =
    match actual_expr, expected_type with
    | Var name, TFunc (expected_params, expected_return) ->
      (match Hashtbl.find_opt user_functions name with
       | Some fd ->
         let actual_params = List.map (fun p -> p.param_type) fd.params in
         if actual_params <> expected_params || fd.return_type <> expected_return then
           errors := (Printf.sprintf "Callable argument %s has the wrong signature" name) :: !errors
       | None ->
         (match StringMap.find_opt name callback_env with
          | Some (TFunc (actual_params, actual_return)) ->
            if actual_params <> expected_params || actual_return <> expected_return then
              errors := (Printf.sprintf "Callable argument %s has the wrong signature" name) :: !errors
          | Some _ ->
            errors := (Printf.sprintf "Argument %s is not callable" name) :: !errors
          | None ->
            errors := (Printf.sprintf "Unknown callable argument: %s" name) :: !errors))
    | _, TFunc _ ->
      errors := "Callable arguments must be passed by name" :: !errors
    | _ -> ()
  in
  let rec check_actuals callback_env actuals formals =
    match actuals, formals with
    | actual :: actual_rest, formal :: formal_rest ->
      check_callable_argument callback_env actual formal.param_type;
      check_actuals callback_env actual_rest formal_rest
    | [], _ | _, [] -> ()
  in
  let rec check_expr callback_env = function
    | IntLit _ | FloatLit _ | BoolLit _ | StringLit _ | Var _ -> ()
    | BinOp (_, l, r) ->
      check_expr callback_env l;
      check_expr callback_env r
    | UnaryOp (_, e) -> check_expr callback_env e
    | Call (name, args) ->
      List.iter (check_expr callback_env) args;
      (match Hashtbl.find_opt user_functions name with
       | Some fd ->
         let provided = List.length args in
         let required =
           List.fold_left (fun count p ->
             match p.default_value with
             | None -> count + 1
             | Some _ -> count
           ) 0 fd.params
         in
         let total = List.length fd.params in
         if provided < required || provided > total then
           errors := (Printf.sprintf
             "Call to %s expects between %d and %d arguments, got %d"
             name required total provided) :: !errors
         else
           check_actuals callback_env args fd.params
       | None ->
         (match StringMap.find_opt name callback_env with
          | Some (TFunc (param_types, _)) ->
            if List.length args <> List.length param_types then
              errors := (Printf.sprintf
                "Call to callback %s expects %d arguments, got %d"
                name (List.length param_types) (List.length args)) :: !errors
          | Some _ -> ()
          | None -> ()))
    | Index (e, subs) ->
      check_expr callback_env e;
      List.iter (check_subscript callback_env) subs
    | CoarrayIndex (e, idxs) ->
      check_expr callback_env e;
      List.iter (check_expr callback_env) idxs
    | FieldAccess (e, _) -> check_expr callback_env e
    | ArrayLit elems -> List.iter (check_expr callback_env) elems
    | RangeExpr (start_e, stop_e, step_e) ->
      check_expr callback_env start_e;
      check_expr callback_env stop_e;
      (match step_e with Some e -> check_expr callback_env e | None -> ())
  and check_subscript callback_env = function
    | IndexSubscript e -> check_expr callback_env e
    | SliceSubscript (start_e, stop_e, step_e) ->
      (match start_e with Some e -> check_expr callback_env e | None -> ());
      (match stop_e with Some e -> check_expr callback_env e | None -> ());
      (match step_e with Some e -> check_expr callback_env e | None -> ())
  and check_stmt callback_env = function
    | Assign (target, value) ->
      check_expr callback_env target;
      check_expr callback_env value
    | VarDecl (_, _, Some e) -> check_expr callback_env e
    | VarDecl (_, _, None) -> ()
    | AugAssign (_, target, value) ->
      check_expr callback_env target;
      check_expr callback_env value
    | Return (Some e) -> check_expr callback_env e
    | Return None -> ()
    | If { cond; body; elifs; else_body } ->
      check_expr callback_env cond;
      List.iter (check_stmt callback_env) body;
      List.iter (fun (elif_cond, elif_body) ->
        check_expr callback_env elif_cond;
        List.iter (check_stmt callback_env) elif_body
      ) elifs;
      List.iter (check_stmt callback_env) else_body
    | For { start_expr; end_expr; step_expr; for_body; _ } ->
      check_expr callback_env start_expr;
      check_expr callback_env end_expr;
      (match step_expr with Some e -> check_expr callback_env e | None -> ());
      List.iter (check_stmt callback_env) for_body
    | While (cond, body) ->
      check_expr callback_env cond;
      List.iter (check_stmt callback_env) body
    | ExprStmt e -> check_expr callback_env e
    | Print args -> List.iter (check_expr callback_env) args
    | SyncAll -> ()
    | Allocate (_, dims) -> List.iter (check_expr callback_env) dims
    | Pass -> ()
  in
  List.iter (function
    | FuncDef { params; body; _ } ->
      let callback_env =
        List.fold_left (fun env p ->
          match p.param_type with
          | TFunc _ -> StringMap.add p.param_name p.param_type env
          | _ -> env
        ) StringMap.empty params
      in
      List.iter (fun p ->
        match p.default_value with
        | Some e -> check_expr StringMap.empty e
        | None -> ()
      ) params;
      List.iter (check_stmt callback_env) body
    | GlobalVarDecl (_, _, Some e) -> check_expr StringMap.empty e
    | GlobalVarDecl (_, _, None) | StructDef _ | Import _ -> ()
  ) program;
  !errors

let validate_top_level_names program =
  let errors = ref [] in
  let seen = Hashtbl.create 32 in
  let note_name kind name =
    if Hashtbl.mem seen name then
      errors := (Printf.sprintf "Duplicate top-level name: %s" name) :: !errors
    else
      Hashtbl.add seen name kind
  in
  List.iter (function
    | Import _ -> ()
    | StructDef (name, _) -> note_name "struct" name
    | FuncDef { func_name; _ } -> note_name "function" func_name
    | GlobalVarDecl (name, _, _) -> note_name "global" name
  ) program;
  !errors

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
        | For { for_body; parallel = true; _ } ->
          if List.exists stmt_uses_coarray for_body then
            errors := "Coarray operations are not allowed inside @par loops" :: !errors;
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
    | Assign _ | AugAssign _ | Return _ | ExprStmt _ | Print _
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
    | TString | TArray _ | TCoarray _ | TStruct _ | TFunc _ | TVoid -> false
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
    | For { var; for_body; parallel; local_vars; local_init_vars; reduce_specs; _ } ->
      let has_do_concurrent_clauses =
        local_vars <> [] || local_init_vars <> [] || reduce_specs <> []
      in
      if has_do_concurrent_clauses && not parallel then
        errors := (Printf.sprintf
          "Loop over %s uses @local/@local_init/@reduce without @par" var) :: !errors;
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
    | Assign _ | VarDecl _ | AugAssign _ | Return _
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

let validate_slices program =
  let errors = ref [] in
  let rec check_expr = function
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
    | Pass -> ()
  in
  List.iter (function
    | FuncDef { body; _ } -> List.iter check_stmt body
    | GlobalVarDecl (_, _, Some e) -> check_expr e
    | GlobalVarDecl (_, _, None) | StructDef _ | Import _ -> ()
  ) program;
  !errors

let validate_plotting program =
  let errors = ref [] in
  let invalid_plot_arity arity =
    arity <> 3 && arity <> 4 && arity <> 6
  in
  let rec check_expr = function
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
    | Pass -> ()
  in
  List.iter (function
    | FuncDef { body; _ } -> List.iter check_stmt body
    | GlobalVarDecl (_, _, Some e) -> check_expr e
    | GlobalVarDecl (_, _, None) | StructDef _ | Import _ -> ()
  ) program;
  !errors

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
  let rec check_expr = function
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
    | Pass -> ()
  in
  List.iter (function
    | FuncDef { body; _ } -> List.iter check_stmt body
    | GlobalVarDecl (_, _, Some e) -> check_expr e
    | GlobalVarDecl (_, _, None) | StructDef _ | Import _ -> ()
  ) program;
  !errors

(* ---- Main check ---- *)
let check program =
  let errors = ref [] in
  (* Check recursion *)
  let call_graph = build_call_graph program in
  errors := !errors @ detect_recursion call_graph;
  (* Check duplicate exported names after import expansion *)
  errors := !errors @ validate_top_level_names program;
  (* Check struct types *)
  errors := !errors @ validate_structs program;
  (* Check callable-parameter restrictions and default-value rules. *)
  errors := !errors @ validate_callable_support program;
  (* Check coarray-specific restrictions *)
  errors := !errors @ validate_coarrays program;
  (* Check do concurrent clause syntax and typing. *)
  errors := !errors @ validate_do_concurrent_features program;
  (* Check slice-specific constraints *)
  errors := !errors @ validate_slices program;
  (* Check builtin plotting usage *)
  errors := !errors @ validate_plotting program;
  (* Check standard-library stubs with custom lowering. *)
  errors := !errors @ validate_stdlib_calls program;
  (* Check user-defined call arity and callable arguments. *)
  errors := !errors @ validate_function_calls program;
  if !errors <> [] then
    raise (SemanticError (String.concat "\n" (List.map (fun e -> "Error: " ^ e) !errors)))

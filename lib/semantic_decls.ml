open Ast
open Semantic_types

(* Validators that operate on top-level declarations: structs, callable usage,
   user-defined call arity, and duplicate top-level names. *)

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

(* Check callable-parameter restrictions and default-value rules. *)
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
    | FString parts -> List.exists (fun p -> match p with FStrExpr (e, _) -> expr_mentions_name target e | FStrLit _ -> false) parts
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
    | Break -> ()
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

(* Check user-defined call arity and callable arguments. *)
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
    | FString parts ->
      List.iter (fun part -> match part with
        | FStrExpr (e, _) -> check_expr callback_env e
        | FStrLit _ -> ()) parts
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
    | Break -> ()
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

(* Check duplicate exported names after import expansion. *)
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

open Ast
open Codegen_state

(* Type-level codegen: callable signatures, index/slice lowering, Fortran type
   declarations, reduction helpers, and AST renaming. *)

(* ---- Constant folding for index expressions ---- *)
let try_const_int = function
  | IntLit n -> Some n
  | UnaryOp (Neg, IntLit n) -> Some (-n)
  | _ -> None

let is_deferred_dim = function
  | DeferredDim -> true
  | FixedDim _ -> false

(* Build the Fortran derived-type name for a generic instantiation:
   CartesianMesh[TemperatureFlow] -> cartesian_mesh_temperatureflow. *)
let monomorphized_type_name base args =
  let arg_part = String.concat "_" (List.map (function
    | TStruct n -> String.lowercase_ascii n
    | TInt -> "int"
    | TFloat -> "float"
    | TBool -> "bool"
    | TString -> "string"
    | _ -> "x"
  ) args) in
  String.lowercase_ascii base ^ "_" ^ arg_part

let rec callable_type_key = function
  | TInt -> "int"
  | TFloat -> "float"
  | TBool -> "bool"
  | TString -> "string"
  | TVoid -> "void"
  | TStruct name -> "struct:" ^ name
  | TGeneric (base, args) ->
    "generic:" ^ base ^ "<" ^ String.concat "," (List.map callable_type_key args) ^ ">"
  | TArray (elem_t, dims) ->
    let dims_key =
      String.concat "," (List.map (function
        | DeferredDim -> ":"
        | FixedDim _ -> "*"
      ) dims)
    in
    "array(" ^ callable_type_key elem_t ^ ";" ^ dims_key ^ ")"
  | TCoarray (elem_t, _) ->
    "coarray(" ^ callable_type_key elem_t ^ ")"
  | TFunc (param_types, return_type) ->
    "callable(" ^ String.concat "," (List.map callable_type_key param_types) ^
    "->" ^ callable_type_key return_type ^ ")"

let callable_interface_name typ =
  match Hashtbl.find_opt callable_interfaces (callable_type_key typ) with
  | Some name -> name
  | None -> failwith "Missing callable interface registration"

let expand_call_args name args =
  match Hashtbl.find_opt user_functions name with
  | None -> args
  | Some fd ->
    let rec fill actuals params =
      match actuals, params with
      | actual :: rest_actuals, _ :: rest_params ->
        actual :: fill rest_actuals rest_params
      | [], param :: rest_params ->
        (match param.default_value with
         | Some default_expr -> default_expr :: fill [] rest_params
         | None -> failwith ("Missing required argument for " ^ name))
      | [], [] -> []
      | _ :: _, [] -> failwith ("Too many arguments for " ^ name)
    in
    fill args fd.params

let call_return_type name =
  match Hashtbl.find_opt user_functions name with
  | Some fd -> Some fd.return_type
  | None ->
    (match Hashtbl.find_opt current_callable_params name with
     | Some (TFunc (_, return_type)) -> Some return_type
     | Some _ -> Some TVoid
     | None -> None)

(* Generate 1-based index expression from 0-based *)
let rec gen_index_expr e =
  match try_const_int e with
  | Some n -> string_of_int (n + 1)
  | None -> (!gen_expr_ref) e ^ " + 1"

and gen_subscript parent_expr dim_index = function
  | IndexSubscript e -> gen_index_expr e
  | SliceSubscript (start_e, stop_e, step_e) ->
    (* Slices become Fortran array sections on the matching dimension. *)
    let lower =
      match start_e with
      | Some e -> gen_index_expr e
      | None -> Printf.sprintf "lbound(%s, %d)" parent_expr dim_index
    in
    let upper =
      match stop_e with
      | Some e -> (!gen_expr_ref) e
      | None -> Printf.sprintf "ubound(%s, %d)" parent_expr dim_index
    in
    let stride =
      match step_e with
      | Some e ->
        (match try_const_int e with
         | Some n when n <= 0 -> failwith "Slice steps must be positive"
         | _ -> ":" ^ (!gen_expr_ref) e)
      | None -> ""
    in
    lower ^ ":" ^ upper ^ stride

(* ---- Type codegen ---- *)
and fortran_type = function
  | TInt -> "integer"
  | TFloat -> "real(8)"
  | TBool -> "logical"
  | TString -> "character(len=:), allocatable"
  | TVoid -> ""
  | TFunc _ -> failwith "Use fortran_type_decl for callable parameters"
  | TStruct name -> "type(" ^ name ^ ")"
  | TGeneric (base, args) -> "type(" ^ monomorphized_type_name base args ^ ")"
  | TArray _ | TCoarray _ -> failwith "Use fortran_type_decl for arrays and coarrays"

and gen_array_dim = function
  | DeferredDim -> ":"
  | FixedDim e -> (!gen_expr_ref) e

and fortran_array_suffix dims =
  "(" ^ String.concat ", " (List.map gen_array_dim dims) ^ ")"

and fortran_array_decl ?intent name elem_t dims =
  let attrs =
    [Some (fortran_base_type elem_t);
     intent;
     if List.for_all is_deferred_dim dims && intent = None then Some "allocatable" else None]
    |> List.filter_map (fun x -> x)
  in
  Printf.sprintf "%s :: %s%s" (String.concat ", " attrs) name (fortran_array_suffix dims)

and fortran_explicit_array_decl ?intent name elem_t dim_names =
  let attrs =
    [Some (fortran_base_type elem_t); intent]
    |> List.filter_map (fun x -> x)
  in
  Printf.sprintf "%s :: %s(%s)"
    (String.concat ", " attrs) name (String.concat ", " dim_names)

and fortran_type_decl ?intent ?(is_local=false) name typ =
  match typ with
  | TString ->
    (match intent with
     | Some "intent(in)" ->
       "character(len=*), intent(in) :: " ^ name
     | Some intent_attr ->
       "character(len=:), allocatable, " ^ intent_attr ^ " :: " ^ name
     | None ->
       "character(len=:), allocatable :: " ^ name)
  | TFunc _ ->
    Printf.sprintf "procedure(%s) :: %s" (callable_interface_name typ) name
  | TStruct struct_name ->
    (match intent with
     | Some intent_attr ->
       (* Non-extended structs lower to a non-polymorphic type(...) dummy so GCC
          can analyze component writes inside do concurrent loops. Only generic
          bases (CartesianMesh) must stay class(...) because their actuals are
          monomorphized subtypes passed via Fortran type extension. *)
       if is_generic_base struct_name then
         Printf.sprintf "class(%s), %s :: %s" struct_name intent_attr name
       else
         Printf.sprintf "type(%s), %s :: %s" struct_name intent_attr name
     | None ->
       Printf.sprintf "type(%s) :: %s" struct_name name)
  | TArray (elem_t, dims) ->
    fortran_array_decl ?intent name elem_t dims
  | TCoarray (TArray (elem_t, dims), extra_codims) ->
    let deferred = List.for_all is_deferred_dim dims in
    let n_extra = List.length extra_codims in
    (* Allocatable: all codims deferred [:, :, ...]; static: extra sizes + final * *)
    let codim_suffix =
      if deferred then
        "[" ^ String.concat ", " (List.init (n_extra + 1) (fun _ -> ":")) ^ "]"
      else if n_extra = 0 then "[*]"
      else
        let extras = List.filter_map (Option.map (fun e -> (!gen_expr_ref) e)) extra_codims in
        "[" ^ String.concat ", " extras ^ ", *]"
    in
    let attrs =
      [Some (fortran_base_type elem_t);
       intent;
       if is_local && not deferred then Some "save" else None;
       if deferred then Some "allocatable" else None]
      |> List.filter_map (fun x -> x)
    in
    Printf.sprintf "%s :: %s%s%s"
      (String.concat ", " attrs) name (fortran_array_suffix dims) codim_suffix
  | TCoarray (elem_t, extra_codims) ->
    (* Scalar coarray; extra codims use their specified sizes + final * *)
    let n_extra = List.length extra_codims in
    let codim_suffix =
      if n_extra = 0 then "[*]"
      else
        let extras = List.filter_map (Option.map (fun e -> (!gen_expr_ref) e)) extra_codims in
        "[" ^ String.concat ", " extras ^ ", *]"
    in
    let attrs =
      [Some (fortran_type elem_t);
       intent;
       if is_local then Some "save" else None]
      |> List.filter_map (fun x -> x)
    in
    Printf.sprintf "%s :: %s%s" (String.concat ", " attrs) name codim_suffix
  | _ ->
    let attrs =
      [Some (fortran_type typ); intent]
      |> List.filter_map (fun x -> x)
    in
    Printf.sprintf "%s :: %s" (String.concat ", " attrs) name

and fortran_base_type = function
  | TStruct name -> "type(" ^ name ^ ")"
  | TFunc _ -> failwith "Unexpected callable base type"
  | TCoarray _ -> failwith "Unexpected nested coarray base type"
  | t -> fortran_type t

let lookup_var_type name =
  match Hashtbl.find_opt current_var_types name with
  | Some typ -> typ
  | None -> failwith ("Missing type for variable " ^ name)

let reduction_identity_expr op name =
  match op, lookup_var_type name with
  | ReduceAdd, TInt -> "0"
  | ReduceAdd, TFloat -> "0.0d0"
  | ReduceMul, TInt -> "1"
  | ReduceMul, TFloat -> "1.0d0"
  | ReduceMax, TInt -> "(-huge(" ^ name ^ "))"
  | ReduceMax, TFloat -> "(-huge(" ^ name ^ "))"
  | ReduceMin, TInt -> "huge(" ^ name ^ ")"
  | ReduceMin, TFloat -> "huge(" ^ name ^ ")"
  | ReduceIand, TInt -> "not(0)"
  | ReduceIor, TInt -> "0"
  | ReduceIeor, TInt -> "0"
  | ReduceAnd, TBool -> ".true."
  | ReduceOr, TBool -> ".false."
  | ReduceEqv, TBool -> ".true."
  | ReduceNeqv, TBool -> ".false."
  | _ -> failwith ("Unsupported reduction identity for " ^ name)

(* OpenMP reduction-identifier text for a reduction operator. Used by @omp loop
   lowering, which emits a native reduction(<op>:<vars>) clause. *)
let omp_reduction_op = function
  | ReduceAdd -> "+"
  | ReduceMul -> "*"
  | ReduceMax -> "max"
  | ReduceMin -> "min"
  | ReduceIand -> "iand"
  | ReduceIor -> "ior"
  | ReduceIeor -> "ieor"
  | ReduceAnd -> ".and."
  | ReduceOr -> ".or."
  | ReduceEqv -> ".eqv."
  | ReduceNeqv -> ".neqv."

let reduction_combine_expr op acc value =
  match op with
  | ReduceAdd -> acc ^ " + " ^ value
  | ReduceMul -> acc ^ " * " ^ value
  | ReduceMax -> "max(" ^ acc ^ ", " ^ value ^ ")"
  | ReduceMin -> "min(" ^ acc ^ ", " ^ value ^ ")"
  | ReduceIand -> "iand(" ^ acc ^ ", " ^ value ^ ")"
  | ReduceIor -> "ior(" ^ acc ^ ", " ^ value ^ ")"
  | ReduceIeor -> "ieor(" ^ acc ^ ", " ^ value ^ ")"
  | ReduceAnd -> acc ^ " .and. " ^ value
  | ReduceOr -> acc ^ " .or. " ^ value
  | ReduceEqv -> acc ^ " .eqv. " ^ value
  | ReduceNeqv -> acc ^ " .neqv. " ^ value

let rec rename_expr env = function
  | Var name ->
    (match List.assoc_opt name env with
     | Some replacement -> Var replacement
     | None -> Var name)
  | BinOp (op, l, r) -> BinOp (op, rename_expr env l, rename_expr env r)
  | UnaryOp (op, e) -> UnaryOp (op, rename_expr env e)
  | Call (name, args) -> Call (name, List.map (rename_expr env) args)
  | Index (e, subs) -> Index (rename_expr env e, List.map (rename_subscript env) subs)
  | CoarrayIndex (e, idxs) -> CoarrayIndex (rename_expr env e, List.map (rename_expr env) idxs)
  | FieldAccess (e, field) -> FieldAccess (rename_expr env e, field)
  | ArrayLit elems -> ArrayLit (List.map (rename_expr env) elems)
  | RangeExpr (start_e, stop_e, step_e) ->
    RangeExpr (rename_expr env start_e, rename_expr env stop_e, Option.map (rename_expr env) step_e)
  | FString parts ->
    FString (List.map (fun p -> match p with FStrExpr (e, fmt) -> FStrExpr (rename_expr env e, fmt) | FStrLit _ -> p) parts)
  | IntLit _ | FloatLit _ | BoolLit _ | StringLit _ as literal -> literal

and rename_subscript env = function
  | IndexSubscript e -> IndexSubscript (rename_expr env e)
  | SliceSubscript (start_e, stop_e, step_e) ->
    SliceSubscript (Option.map (rename_expr env) start_e,
                    Option.map (rename_expr env) stop_e,
                    Option.map (rename_expr env) step_e)

let rec rename_stmt env = function
  | Assign (target, value) -> Assign (rename_expr env target, rename_expr env value)
  | VarDecl (name, typ, init) -> VarDecl (name, typ, Option.map (rename_expr env) init)
  | AugAssign (op, target, value) -> AugAssign (op, rename_expr env target, rename_expr env value)
  | Return e -> Return (Option.map (rename_expr env) e)
  | If { cond; body; elifs; else_body } ->
    If {
      cond = rename_expr env cond;
      body = List.map (rename_stmt env) body;
      elifs = List.map (fun (elif_cond, elif_body) ->
        (rename_expr env elif_cond, List.map (rename_stmt env) elif_body)
      ) elifs;
      else_body = List.map (rename_stmt env) else_body;
    }
  | For ({ var; start_expr; end_expr; step_expr; for_body; _ } as loop) ->
    let renamed_var = match List.assoc_opt var env with  (* Privatize inner loop vars. *)
      | Some replacement -> replacement
      | None -> var
    in
    For { loop with
      var = renamed_var;
      start_expr = rename_expr env start_expr;
      end_expr = rename_expr env end_expr;
      step_expr = Option.map (rename_expr env) step_expr;
      for_body = List.map (rename_stmt env) for_body }
  | While (cond, body) -> While (rename_expr env cond, List.map (rename_stmt env) body)
  | ExprStmt e -> ExprStmt (rename_expr env e)
  | Print args -> Print (List.map (rename_expr env) args)
  | SyncAll -> SyncAll
  | Allocate (name, dims) -> Allocate (name, List.map (rename_expr env) dims)
  | Break -> Break
  | Pass -> Pass

open Ast
open Fortran_helpers

(* ---- Fortran Code Generator ---- *)

let indent_str n = String.make (n * 2) ' '

(* Built-in function mapping: FortScript name -> Fortran name *)
let builtin_funcs = [
  (* NumPy-like *)
  "dot",       "dot_product";
  "matmul",    "matmul";
  "transpose", "transpose";
  "sum",       "sum";
  "product",   "product";
  "minval",    "minval";
  "maxval",    "maxval";
  "size",      "size";
  "shape",     "shape";
  "abs",       "abs";
  "sqrt",      "sqrt";
  "sin",       "sin";
  "cos",       "cos";
  "tan",       "tan";
  "exp",       "exp";
  "log",       "log";
  "floor",     "floor";
  "ceiling",   "ceiling";
  "mod",       "mod";
  (* Fortran-specific *)
  "reshape",   "reshape";
  "spread",    "spread";
  "pack",      "pack";
  "merge",     "merge";
  "any",       "any";
  "all",       "all";
  "count",     "count";
]

let is_builtin name = List.mem_assoc name builtin_funcs
let fortran_builtin name = List.assoc name builtin_funcs
let plot_builtins = ["plot"; "histogram"; "scatter"; "imshow"; "contour"; "contourf"]
let is_plot_builtin name = List.mem name plot_builtins
(* HDF5 I/O builtins backed by the h5fortran high-level interface. *)
let h5_builtins = ["h5write"; "h5read"]
let is_h5_builtin name = List.mem name h5_builtins

(* Coarray collective subroutines: must be used as statements, not expressions. *)
let coarray_collectives = ["co_sum"; "co_min"; "co_max"; "co_broadcast"; "co_reduce"]
let is_coarray_collective name = List.mem name coarray_collectives
let lapack_qr_enabled = ref false  (* Tracks whether support.linalg.qr should lower to LAPACK. *)
let lapack_solve_enabled = ref false  (* Tracks whether support.linalg.solve should lower to LAPACK. *)
let lapack_svd_enabled = ref false  (* Tracks whether support.linalg.svd should lower to LAPACK. *)
let lapack_eig_enabled = ref false  (* Tracks whether support.linalg.eig should lower to LAPACK. *)
let coarrays_enabled = ref false  (* Tracks whether the program uses coarrays. *)

let is_two_dim_float_array = function
  | TArray (TFloat, [DeferredDim; DeferredDim]) -> true
  | _ -> false

let is_one_dim_float_array = function
  | TArray (TFloat, [DeferredDim]) -> true
  | _ -> false

let is_lapack_qr_stub fd =
  fd.func_name = "qr" &&
  fd.return_type = TVoid &&
  List.length fd.params = 3 &&
  List.for_all (fun p -> is_two_dim_float_array p.param_type) fd.params &&
  fd.body = [Pass]  (* A pass-only stub marks a support-library lowering point. *)

let is_lapack_svd_stub fd =
  fd.func_name = "svd" &&
  fd.return_type = TVoid &&
  List.length fd.params = 4 &&
  (match fd.params with
   | [a_param; u_param; s_param; vt_param] ->
     is_two_dim_float_array a_param.param_type &&
     is_two_dim_float_array u_param.param_type &&
     is_one_dim_float_array s_param.param_type &&
     is_two_dim_float_array vt_param.param_type
   | _ -> false) &&
  fd.body = [Pass]  (* A pass-only stub marks a support-library lowering point. *)

(* Detect the support.linalg.eig stub: 4 args (a, wr, wi, vr) of the right shape. *)
let is_lapack_eig_stub fd =
  fd.func_name = "eig" &&
  fd.return_type = TVoid &&
  List.length fd.params = 4 &&
  (match fd.params with
   | [a_param; wr_param; wi_param; vr_param] ->
     is_two_dim_float_array a_param.param_type &&
     is_one_dim_float_array wr_param.param_type &&
     is_one_dim_float_array wi_param.param_type &&
     is_two_dim_float_array vr_param.param_type
   | _ -> false) &&
  fd.body = [Pass]  (* A pass-only stub marks a support-library lowering point. *)

let is_lapack_solve_stub fd =
  fd.func_name = "solve" &&
  fd.return_type = TVoid &&
  List.length fd.params = 3 &&
  (match fd.params with
   | [a_param; b_param; x_param] ->
     is_two_dim_float_array a_param.param_type &&
     is_one_dim_float_array b_param.param_type &&
     is_one_dim_float_array x_param.param_type
   | _ -> false) &&
  fd.body = [Pass]  (* A pass-only stub marks a support-library lowering point. *)

(* Track user-defined function signatures for default-arg expansion. *)
let user_functions : (string, func_def) Hashtbl.t = Hashtbl.create 16

(* Track which functions must be 'pure' (called from do concurrent blocks) *)
let pure_functions : (string, bool) Hashtbl.t = Hashtbl.create 16

(* Track callable dummy arguments visible in the current function. *)
let current_callable_params : (string, typ) Hashtbl.t = Hashtbl.create 16

(* Track coarray declarations; value is the count of extra leading codimensions. *)
let coarray_vars : (string, int) Hashtbl.t = Hashtbl.create 32
let global_coarray_vars : (string, int) Hashtbl.t = Hashtbl.create 32
let global_var_types : (string, typ) Hashtbl.t = Hashtbl.create 32

(* Track generated abstract interfaces for callable signatures. *)
let callable_interfaces : (string, string) Hashtbl.t = Hashtbl.create 16
let current_var_types : (string, typ) Hashtbl.t = Hashtbl.create 64
let parallel_feature_counter = ref 0
let gpu_kernel_counter = ref 0
let current_proc_name : string option ref = ref None
let gen_expr_ref : (expr -> string) ref =
  ref (fun _ -> failwith "gen_expr not initialized")
let gen_procedure_ref : (int -> func_def list -> bool -> func_def -> string) ref =
  ref (fun _ _ _ _ -> failwith "gen_procedure not initialized")

type gpu_kernel_artifact = {
  name: string;
  filename: string;
  params: param list;
  body: stmt list;
  source: string;
}

type generated_output = {
  main_source: string;
  gpu_kernels: gpu_kernel_artifact list;
}

let gpu_kernels : gpu_kernel_artifact list ref = ref []

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
  | If { cond; body; elifs; else_body } ->
    collect_calls_expr cond @
    collect_calls_stmts body @
    List.concat_map (fun (c, b) -> collect_calls_expr c @ collect_calls_stmts b) elifs @
    collect_calls_stmts else_body
  | For { for_body; _ } -> collect_calls_stmts for_body
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
  | _ -> []

and collect_calls_subscript = function
  | IndexSubscript e -> collect_calls_expr e
  | SliceSubscript (start_e, stop_e, step_e) ->
    (* Slice bounds can themselves call functions. *)
    let calls = match start_e with Some e -> collect_calls_expr e | None -> [] in
    let calls = match stop_e with Some e -> calls @ collect_calls_expr e | None -> calls in
    (match step_e with Some e -> calls @ collect_calls_expr e | None -> calls)

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
    | Assign _ | AugAssign _ | Return _ | ExprStmt _ | Print _
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
  | Assign _ | VarDecl _ | AugAssign _ | Return _
  | ExprStmt _ | Print _ | SyncAll | Allocate _ | Pass ->
    false

(* ---- Constant folding for index expressions ---- *)
let try_const_int = function
  | IntLit n -> Some n
  | UnaryOp (Neg, IntLit n) -> Some (-n)
  | _ -> None

let is_deferred_dim = function
  | DeferredDim -> true
  | FixedDim _ -> false

let rec callable_type_key = function
  | TInt -> "int"
  | TFloat -> "float"
  | TBool -> "bool"
  | TString -> "string"
  | TVoid -> "void"
  | TStruct name -> "struct:" ^ name
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
  | TString -> "character(len=256)"
  | TVoid -> ""
  | TFunc _ -> failwith "Use fortran_type_decl for callable parameters"
  | TStruct name -> "type(" ^ name ^ ")"
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
  | TFunc _ ->
    Printf.sprintf "procedure(%s) :: %s" (callable_interface_name typ) name
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
  | Pass -> Pass

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

(* ---- Expression codegen ---- *)
and gen_expr = function
  | IntLit n -> string_of_int n
  | FloatLit f ->
    let s = Printf.sprintf "%.15g" f in
    if String.contains s 'e' || String.contains s 'E' then
      Str.global_replace (Str.regexp "[eE]") "d" s
    else if String.contains s '.' then
      s ^ "d0"
    else
      s ^ ".0d0"
  | BoolLit true -> ".true."
  | BoolLit false -> ".false."
  | StringLit s -> "\"" ^ s ^ "\""
  | Var name -> name
  | BinOp (op, l, r) -> gen_binop op l r
  | UnaryOp (Neg, e) -> "(-" ^ gen_expr e ^ ")"
  | UnaryOp (Not, e) -> "(.not. " ^ gen_expr e ^ ")"
  | Call (name, args) -> gen_call name args
  | Index (e, subs) ->
    let parent = gen_expr e in
    let sub_strs =
      List.mapi (fun i sub -> gen_subscript parent (i + 1) sub) subs
    in
    parent ^ "(" ^ String.concat ", " sub_strs ^ ")"
  | CoarrayIndex (e, idxs) ->
    gen_expr e ^ "[" ^ String.concat ", " (List.map gen_index_expr idxs) ^ "]"
  | FieldAccess (e, field) ->
    gen_expr e ^ "%" ^ field
  | ArrayLit elems ->
    let elems_str = String.concat ", " (List.map gen_expr elems) in
    "(/ " ^ elems_str ^ " /)"
  | RangeExpr _ -> failwith "RangeExpr should not appear in codegen"

and gen_binop op l r =
  let ls = gen_expr l and rs = gen_expr r in
  match op with
  | Mod -> Printf.sprintf "mod(%s, %s)" ls rs
  | Pow -> Printf.sprintf "(%s**%s)" ls rs
  | _ ->
    let op_str = match op with
      | Add -> " + " | Sub -> " - " | Mul -> " * " | Div -> " / "
      | Eq -> " == " | Neq -> " /= " | Lt -> " < " | Gt -> " > "
      | Le -> " <= " | Ge -> " >= "
      | And -> " .and. " | Or -> " .or. "
      | _ -> failwith "unreachable"
    in
    Printf.sprintf "(%s%s%s)" ls op_str rs

and gen_call name args =
  let lowered_args = expand_call_args name args in
  let args_str = String.concat ", " (List.map gen_expr lowered_args) in
  if name = "exit" then
    failwith "exit() can only be used as a standalone statement"
  else if is_plot_builtin name then
    failwith "plot() can only be used as a standalone statement"
  else if is_h5_builtin name then
    failwith (name ^ "() can only be used as a standalone statement")
  else if !lapack_qr_enabled && name = "qr" then
    failwith "qr() can only be used as a standalone statement"
  else if !lapack_solve_enabled && name = "solve" then
    failwith "solve() can only be used as a standalone statement"
  else if !lapack_svd_enabled && name = "svd" then
    failwith "svd() can only be used as a standalone statement"
  else if !lapack_eig_enabled && name = "eig" then
    failwith "eig() can only be used as a standalone statement"
  else if is_coarray_collective name then
    failwith (name ^ "() can only be used as a standalone statement")
  else if name = "this_image" then
    "(this_image() - 1)"
  else if name = "num_images" then
    "num_images()"
  else if is_builtin name then
    Printf.sprintf "%s(%s)" (fortran_builtin name) args_str
  else if name = "zeros" then
    (match lowered_args with
     | [n] -> Printf.sprintf "spread(0.0d0, 1, %s)" (gen_expr n)
     | _ -> Printf.sprintf "spread(0.0d0, 1, %s)" args_str)
  else if name = "ones" then
    (match lowered_args with
     | [n] -> Printf.sprintf "spread(1.0d0, 1, %s)" (gen_expr n)
     | _ -> Printf.sprintf "spread(1.0d0, 1, %s)" args_str)
  else if name = "linspace" then
    (match lowered_args with
     | [start_e; stop_e; n_e] ->
       let s = gen_expr start_e and e = gen_expr stop_e and n = gen_expr n_e in
       Printf.sprintf "[((%s + (%s - %s) * dble(fortscript_i__) / dble(%s - 1)), fortscript_i__ = 0, %s - 1)]"
         s e s n n
     | _ -> failwith "linspace requires 3 arguments")
  else if name = "arange" then
    (match lowered_args with
     | [stop_e] -> Printf.sprintf "[(fortscript_i__, fortscript_i__ = 0, %s - 1)]" (gen_expr stop_e)
     | [start_e; stop_e] ->
       Printf.sprintf "[(fortscript_i__, fortscript_i__ = %s, %s - 1)]" (gen_expr start_e) (gen_expr stop_e)
     | _ -> failwith "arange requires 1-2 arguments")
  else
    (* User-defined function: use direct call syntax for functions *)
    Printf.sprintf "%s(%s)" name args_str

let gen_plot_stmt indent args =
  let ind = indent_str indent in
  match args with
  | [x_e; y_e; file_e] ->
    Printf.sprintf "%scall fortscript_plot_xy__(%s, %s, %s, \"\", \"\", \"\")"
      ind (gen_expr x_e) (gen_expr y_e) (gen_expr file_e)
  | [x_e; y_e; file_e; title_e] ->
    Printf.sprintf "%scall fortscript_plot_xy__(%s, %s, %s, %s, \"\", \"\")"
      ind (gen_expr x_e) (gen_expr y_e) (gen_expr file_e) (gen_expr title_e)
  | [x_e; y_e; file_e; title_e; xlabel_e; ylabel_e] ->
    Printf.sprintf "%scall fortscript_plot_xy__(%s, %s, %s, %s, %s, %s)"
      ind (gen_expr x_e) (gen_expr y_e) (gen_expr file_e)
      (gen_expr title_e) (gen_expr xlabel_e) (gen_expr ylabel_e)
  | _ ->
    failwith "plot() expects 3, 4, or 6 arguments"

let gen_histogram_stmt indent args =
  let ind = indent_str indent in
  match args with
  | [x_e; file_e] ->
    Printf.sprintf "%scall fortscript_histogram__(%s, %s, \"\", \"\", \"\", 10)"
      ind (gen_expr x_e) (gen_expr file_e)
  | [x_e; file_e; title_e] ->
    Printf.sprintf "%scall fortscript_histogram__(%s, %s, %s, \"\", \"\", 10)"
      ind (gen_expr x_e) (gen_expr file_e) (gen_expr title_e)
  | [x_e; file_e; title_e; xlabel_e; ylabel_e] ->
    Printf.sprintf "%scall fortscript_histogram__(%s, %s, %s, %s, %s, 10)"
      ind (gen_expr x_e) (gen_expr file_e) (gen_expr title_e) (gen_expr xlabel_e) (gen_expr ylabel_e)
  | [x_e; file_e; title_e; xlabel_e; ylabel_e; bins_e] ->
    Printf.sprintf "%scall fortscript_histogram__(%s, %s, %s, %s, %s, %s)"
      ind (gen_expr x_e) (gen_expr file_e) (gen_expr title_e) (gen_expr xlabel_e) (gen_expr ylabel_e) (gen_expr bins_e)
  | _ ->
    failwith "histogram() expects 2, 3, 5, or 6 arguments"

let gen_scatter_stmt indent args =
  let ind = indent_str indent in
  match args with
  | [x_e; y_e; file_e] ->
    Printf.sprintf "%scall fortscript_scatter__(%s, %s, %s, \"\", \"\", \"\")"
      ind (gen_expr x_e) (gen_expr y_e) (gen_expr file_e)
  | [x_e; y_e; file_e; title_e] ->
    Printf.sprintf "%scall fortscript_scatter__(%s, %s, %s, %s, \"\", \"\")"
      ind (gen_expr x_e) (gen_expr y_e) (gen_expr file_e) (gen_expr title_e)
  | [x_e; y_e; file_e; title_e; xlabel_e; ylabel_e] ->
    Printf.sprintf "%scall fortscript_scatter__(%s, %s, %s, %s, %s, %s)"
      ind (gen_expr x_e) (gen_expr y_e) (gen_expr file_e) (gen_expr title_e) (gen_expr xlabel_e) (gen_expr ylabel_e)
  | _ ->
    failwith "scatter() expects 3, 4, or 6 arguments"

let gen_imshow_stmt indent args =
  let ind = indent_str indent in
  match args with
  | [z_e; file_e] ->
    Printf.sprintf "%scall fortscript_imshow__(%s, %s, \"\")"
      ind (gen_expr z_e) (gen_expr file_e)
  | [z_e; file_e; title_e] ->
    Printf.sprintf "%scall fortscript_imshow__(%s, %s, %s)"
      ind (gen_expr z_e) (gen_expr file_e) (gen_expr title_e)
  | _ ->
    failwith "imshow() expects 2 or 3 arguments"

(* Shared emitter for contour and contourf; name determines the filled flag. *)
let gen_contour_stmt indent name args =
  let ind = indent_str indent in
  let filled = if name = "contourf" then ".true." else ".false." in
  match args with
  | [x_e; y_e; z_e; file_e] ->
    Printf.sprintf "%scall fortscript_contour__(%s, %s, %s, %s, \"\", \"\", \"\", %s)"
      ind (gen_expr x_e) (gen_expr y_e) (gen_expr z_e) (gen_expr file_e) filled
  | [x_e; y_e; z_e; file_e; title_e] ->
    Printf.sprintf "%scall fortscript_contour__(%s, %s, %s, %s, %s, \"\", \"\", %s)"
      ind (gen_expr x_e) (gen_expr y_e) (gen_expr z_e) (gen_expr file_e) (gen_expr title_e) filled
  | [x_e; y_e; z_e; file_e; title_e; xlabel_e; ylabel_e] ->
    Printf.sprintf "%scall fortscript_contour__(%s, %s, %s, %s, %s, %s, %s, %s)"
      ind (gen_expr x_e) (gen_expr y_e) (gen_expr z_e) (gen_expr file_e)
      (gen_expr title_e) (gen_expr xlabel_e) (gen_expr ylabel_e) filled
  | _ ->
    failwith (name ^ "() expects 4, 5, or 7 arguments")

(* Emit a Fortran coarray collective subroutine call.
   co_sum(a), co_min(a), co_max(a) -> call co_sum(a) etc.
   co_broadcast(a, source_image) -> call co_broadcast(a, source_image + 1)
   co_reduce(a, op) -> call co_reduce(a, op) *)
let gen_coarray_collective_stmt indent name args =
  let ind = indent_str indent in
  match name, args with
  | ("co_sum" | "co_min" | "co_max"), [a_e] ->
    Printf.sprintf "%scall %s(%s)" ind name (gen_expr a_e)
  | "co_broadcast", [a_e; src_e] ->
    (* source_image is 0-based in FortScript, 1-based in Fortran *)
    Printf.sprintf "%scall co_broadcast(%s, %s)" ind (gen_expr a_e) (gen_index_expr src_e)
  | "co_reduce", [a_e; op_e] ->
    Printf.sprintf "%scall co_reduce(%s, %s)" ind (gen_expr a_e) (gen_expr op_e)
  | _ ->
    failwith (Printf.sprintf "%s() called with wrong number of arguments" name)

(* Emit a one-shot HDF5 read or write call. The h5fortran high-level
   interface (h5write/h5read) is generic over scalar/1D-7D arrays of
   integer/real/etc., so we just forward the FortScript arguments. *)
let gen_h5_stmt indent name args =
  let ind = indent_str indent in
  match args with
  | [file_e; dname_e; data_e] ->
    Printf.sprintf "%scall %s(%s, %s, %s)"
      ind name (gen_expr file_e) (gen_expr dname_e) (gen_expr data_e)
  | _ ->
    failwith (name ^ "() expects 3 arguments: filename, dataset_name, value")

let gen_lapack_qr_stmt indent args =
  let ind = indent_str indent in
  match args with
  | [a_e; q_e; r_e] ->
    Printf.sprintf "%scall fortscript_lapack_qr__(%s, %s, %s)"
      ind (gen_expr a_e) (gen_expr q_e) (gen_expr r_e)
  | _ ->
    failwith "qr() expects 3 arguments: a, q, r"

let gen_lapack_svd_stmt indent args =
  let ind = indent_str indent in
  match args with
  | [a_e; u_e; s_e; vt_e] ->
    Printf.sprintf "%scall fortscript_lapack_svd__(%s, %s, %s, %s)"
      ind (gen_expr a_e) (gen_expr u_e) (gen_expr s_e) (gen_expr vt_e)
  | _ ->
    failwith "svd() expects 4 arguments: a, u, s, vt"

(* Lower an eig() call to a call into the generated dgeev wrapper. *)
let gen_lapack_eig_stmt indent args =
  let ind = indent_str indent in
  match args with
  | [a_e; wr_e; wi_e; vr_e] ->
    Printf.sprintf "%scall fortscript_lapack_eig__(%s, %s, %s, %s)"
      ind (gen_expr a_e) (gen_expr wr_e) (gen_expr wi_e) (gen_expr vr_e)
  | _ ->
    failwith "eig() expects 4 arguments: a, wr, wi, vr"

let gen_lapack_solve_stmt indent args =
  let ind = indent_str indent in
  match args with
  | [a_e; b_e; x_e] ->
    Printf.sprintf "%scall fortscript_lapack_solve__(%s, %s, %s)"
      ind (gen_expr a_e) (gen_expr b_e) (gen_expr x_e)
  | _ ->
    failwith "solve() expects 3 arguments: a, b, x"

let () = gen_expr_ref := gen_expr

(* ---- Detect if a subroutine modifies a parameter ---- *)
(* Check if a parameter name appears as an lvalue in any statement *)
let rec param_is_modified param_name stmts =
  List.exists (stmt_modifies param_name) stmts

and stmt_modifies pname = function
  | Assign (target, _) -> lvalue_references pname target
  | AugAssign (_, target, _) -> lvalue_references pname target
  | If { body; elifs; else_body; _ } ->
    param_is_modified pname body ||
    List.exists (fun (_, b) -> param_is_modified pname b) elifs ||
    param_is_modified pname else_body
  | For { for_body; _ } -> param_is_modified pname for_body
  | While (_, body) -> param_is_modified pname body
  | SyncAll | Allocate _ -> false
  | _ -> false

and lvalue_references pname = function
  | Var n -> n = pname
  | Index (e, _) -> lvalue_references pname e
  | CoarrayIndex (e, _) -> lvalue_references pname e
  | FieldAccess (e, _) -> lvalue_references pname e
  | _ -> false

let make_gpu_kernel_params loop helpers =
  List.map (fun name ->
    let param_type = lookup_var_type name in
    { param_name = name; param_type; default_value = None }
  ) (collect_gpu_kernel_params loop helpers)

let gpu_dim_param_names name dims =
  List.mapi (fun i _ -> Printf.sprintf "%s_dim%d" name (i + 1)) dims

let gpu_signature_names params =
  List.concat_map (fun p ->
    match p.param_type with
    | TArray (_, dims) -> gpu_dim_param_names p.param_name dims @ [p.param_name]
    | _ -> [p.param_name]
  ) params

let gpu_actual_args params =
  List.concat_map (fun p ->
    match p.param_type with
    | TArray (_, dims) ->
      let dim_args =
        List.mapi (fun i _ -> Printf.sprintf "size(%s, %d)" p.param_name (i + 1)) dims
      in
      dim_args @ [p.param_name]
    | _ -> [p.param_name]
  ) params

let emit_gpu_param_decls buf proc_ind (pseudo_fd : func_def) params =
  List.iter (fun p ->
    match p.param_type with
    | TArray (elem_t, dims) ->
      let dim_names = gpu_dim_param_names p.param_name dims in
      List.iter (fun dim_name ->
        Buffer.add_string buf (Printf.sprintf "%s  integer, intent(in) :: %s\n" proc_ind dim_name)
      ) dim_names;
      let modified = param_is_modified p.param_name pseudo_fd.body in
      let intent = if modified then "intent(inout)" else "intent(in)" in
      Buffer.add_string buf (Printf.sprintf "%s  %s\n" proc_ind
        (fortran_explicit_array_decl ~intent p.param_name elem_t dim_names))
    | _ ->
      let modified = param_is_modified p.param_name pseudo_fd.body in
      let intent = if modified then "intent(inout)" else "intent(in)" in
      Buffer.add_string buf (Printf.sprintf "%s  %s\n" proc_ind
        (fortran_type_decl ~intent p.param_name p.param_type))
  ) params

(* ---- Statement codegen ---- *)
let rec gen_stmt indent stmt =
  let ind = indent_str indent in
  match stmt with
  | Assign (target, value) ->
    Printf.sprintf "%s%s = %s" ind (gen_lvalue target) (gen_expr value)

  | VarDecl (name, _, Some init) ->
    (* Emit initialization at point of declaration *)
    Printf.sprintf "%s%s = %s" ind name (gen_expr init)

  | VarDecl (_, _, None) ->
    ""  (* declaration only — hoisted to top *)

  | AugAssign (op, target, value) ->
    let t = gen_lvalue target in
    let v = gen_expr value in
    let op_str = match op with
      | Add -> " + " | Sub -> " - " | Mul -> " * " | Div -> " / "
      | _ -> failwith "unsupported augmented assignment operator"
    in
    Printf.sprintf "%s%s = %s%s%s" ind t t op_str v

  | Return (Some e) ->
    Printf.sprintf "%s__RETURN__ %s" ind (gen_expr e)

  | Return None ->
    Printf.sprintf "%sreturn" ind

  | If { cond; body; elifs; else_body } ->
    let buf = Buffer.create 256 in
    Buffer.add_string buf (Printf.sprintf "%sif (%s) then\n" ind (gen_expr cond));
    gen_stmts_into buf (indent + 1) body;
    List.iter (fun (c, b) ->
      Buffer.add_string buf (Printf.sprintf "%selse if (%s) then\n" ind (gen_expr c));
      gen_stmts_into buf (indent + 1) b
    ) elifs;
    (if else_body <> [] then begin
      Buffer.add_string buf (Printf.sprintf "%selse\n" ind);
      gen_stmts_into buf (indent + 1) else_body
    end);
    Buffer.add_string buf (Printf.sprintf "%send if" ind);
    Buffer.contents buf

  | For { var; start_expr; end_expr; step_expr; for_body; parallel; gpu;
          local_vars; local_init_vars; reduce_specs } ->
    let buf = Buffer.create 256 in
    (* Keep loop variable 0-based (matching FortScript semantics) so that
       array indexing with +1 offset is always correct. range(n) -> 0..n-1 *)
    let start_f = gen_expr start_expr in
    let end_f = gen_expr end_expr ^ " - 1" in
    let has_features = local_vars <> [] || local_init_vars <> [] || reduce_specs <> [] in
    if gpu then
      gen_gpu_kernel_call indent {
        var;
        start_expr;
        end_expr;
        step_expr;
        for_body;
        parallel;
        gpu;
        local_vars;
        local_init_vars;
        reduce_specs;
      }
    else begin
      if parallel && has_features then begin
        (* Emit native Fortran 2018 do concurrent with LOCAL / LOCAL_INIT
           clauses instead of the old block-construct workaround.  Reductions
           still use a per-iteration array that is summed sequentially
           afterwards because gfortran does not yet parallelize REDUCE. *)
        incr parallel_feature_counter;
        let feature_id = !parallel_feature_counter in
        let _step_f = match step_expr with Some step -> gen_expr step | None -> "1" in
        let reduce_slots =
          List.concat_map (fun spec ->
            List.map (fun name ->
              let array_name = Printf.sprintf "fortscript_reduce_%s__%d" name feature_id in
              (spec.reduce_op, name, array_name)
            ) spec.reduce_vars
          ) reduce_specs
        in
        let reduce_var_names = List.map (fun (_, n, _) -> n) reduce_slots in
        let already_local = var :: local_vars @ local_init_vars @ reduce_var_names in
        let inner_loop_vars =
          let all_vars = collect_inner_loop_vars for_body in
          let unique_vars = List.sort_uniq String.compare all_vars in
          List.filter (fun v -> not (List.mem v already_local)) unique_vars
        in
        let local_names = local_vars @ reduce_var_names @ inner_loop_vars in
        let local_clause = match local_names with
          | [] -> ""
          | names -> " local(" ^ String.concat ", " names ^ ")"
        in
        let local_init_clause = match local_init_vars with
          | [] -> ""
          | names -> " local_init(" ^ String.concat ", " names ^ ")"
        in
        let iter_name = Printf.sprintf "fortscript_iter__%d" feature_id in
        if reduce_slots <> [] then begin
          Buffer.add_string buf (Printf.sprintf "%sblock\n" ind);
          Buffer.add_string buf (Printf.sprintf "%s  integer :: %s\n" ind iter_name);
          List.iter (fun (_, orig, array_name) ->
            Buffer.add_string buf (Printf.sprintf "%s  %s\n" ind
              (fortran_array_decl array_name (lookup_var_type orig) [DeferredDim]))
          ) reduce_slots;
          Buffer.add_string buf (Printf.sprintf "%s  allocate(" ind);
          Buffer.add_string buf (String.concat ", " (List.map (fun (_, _, a) ->
            Printf.sprintf "%s(%s)" a (gen_expr end_expr)) reduce_slots));
          Buffer.add_string buf ")\n"
        end;
        (match step_expr with
         | None ->
           Buffer.add_string buf (Printf.sprintf "%s  do concurrent (%s = %s:%s)%s%s\n"
             ind var start_f end_f local_clause local_init_clause)
         | Some step ->
           Buffer.add_string buf (Printf.sprintf "%s  do concurrent (%s = %s:%s:%s)%s%s\n"
             ind var start_f end_f (gen_expr step) local_clause local_init_clause));
        List.iter (fun (op, orig, _) ->
          Buffer.add_string buf (Printf.sprintf "%s    %s = %s\n" ind orig
            (reduction_identity_expr op orig))
        ) reduce_slots;
        gen_stmts_into buf (indent + 2) for_body;
        List.iter (fun (_, orig, array_name) ->
          Buffer.add_string buf (Printf.sprintf "%s    %s(%s + 1) = %s\n"
            ind array_name var orig)
        ) reduce_slots;
        Buffer.add_string buf (Printf.sprintf "%s  end do\n" ind);
        if reduce_slots <> [] then begin
          List.iter (fun (op, orig, array_name) ->
            Buffer.add_string buf (Printf.sprintf "%s  %s = %s\n" ind orig
              (reduction_identity_expr op orig));
            Buffer.add_string buf (Printf.sprintf "%s  do %s = 0, %s - 1\n"
              ind iter_name (gen_expr end_expr));
            Buffer.add_string buf (Printf.sprintf "%s    %s = %s\n" ind orig
              (reduction_combine_expr op orig
                 (Printf.sprintf "%s(%s + 1)" array_name iter_name)));
            Buffer.add_string buf (Printf.sprintf "%s  end do\n" ind)
          ) reduce_slots;
          Buffer.add_string buf (Printf.sprintf "%send block" ind)
        end
      end else if parallel then begin
        (match step_expr with
         | None ->
           Buffer.add_string buf (Printf.sprintf "%sdo concurrent (%s = %s:%s)\n"
             ind var start_f end_f)
         | Some step ->
           Buffer.add_string buf (Printf.sprintf "%sdo concurrent (%s = %s:%s:%s)\n"
             ind var start_f end_f (gen_expr step)));
        gen_stmts_into buf (indent + 1) for_body;
        Buffer.add_string buf (Printf.sprintf "%send do" ind)
      end else begin
        (match step_expr with
         | None ->
           Buffer.add_string buf (Printf.sprintf "%sdo %s = %s, %s\n" ind var start_f end_f)
         | Some step ->
           Buffer.add_string buf (Printf.sprintf "%sdo %s = %s, %s, %s\n" ind var start_f end_f (gen_expr step)));
        gen_stmts_into buf (indent + 1) for_body;
        Buffer.add_string buf (Printf.sprintf "%send do" ind)
      end;
      Buffer.contents buf
    end

  | While (cond, body) ->
    let buf = Buffer.create 256 in
    Buffer.add_string buf (Printf.sprintf "%sdo while (%s)\n" ind (gen_expr cond));
    gen_stmts_into buf (indent + 1) body;
    Buffer.add_string buf (Printf.sprintf "%send do" ind);
    Buffer.contents buf

  | ExprStmt (Call (name, args)) ->
    let lowered_args = expand_call_args name args in
    if name = "exit" then
      (match lowered_args with
       | [code_e] -> Printf.sprintf "%sstop %s" ind (gen_expr code_e)
       | _ -> failwith "exit() expects exactly 1 argument")
    else if name = "plot" then
      gen_plot_stmt indent lowered_args
    else if name = "histogram" then
      gen_histogram_stmt indent lowered_args
    else if name = "scatter" then
      gen_scatter_stmt indent lowered_args
    else if name = "imshow" then
      gen_imshow_stmt indent lowered_args
    else if name = "contour" || name = "contourf" then
      gen_contour_stmt indent name lowered_args
    else if !lapack_qr_enabled && name = "qr" then
      gen_lapack_qr_stmt indent lowered_args
    else if !lapack_solve_enabled && name = "solve" then
      gen_lapack_solve_stmt indent lowered_args
    else if !lapack_svd_enabled && name = "svd" then
      gen_lapack_svd_stmt indent lowered_args
    else if !lapack_eig_enabled && name = "eig" then
      gen_lapack_eig_stmt indent lowered_args
    else if is_coarray_collective name then
      gen_coarray_collective_stmt indent name lowered_args
    else if is_h5_builtin name then
      gen_h5_stmt indent name lowered_args
    else if is_builtin name then
      Printf.sprintf "%s! %s(%s)  ! expression result unused" ind name
        (String.concat ", " (List.map gen_expr lowered_args))
    else begin
      let args_str = String.concat ", " (List.map gen_expr lowered_args) in
      (* Statement calls lower to 'call' for subroutines and ignore function results. *)
      match call_return_type name with
      | Some TVoid | None -> Printf.sprintf "%scall %s(%s)" ind name args_str
      | Some _ -> Printf.sprintf "%s! %s(%s)  ! function result unused" ind name args_str
    end

  | ExprStmt _ -> ""

  | Print args ->
    let args_str = String.concat ", " (List.map gen_expr args) in
    Printf.sprintf "%swrite(*, *) %s" ind args_str

  | SyncAll ->
    Printf.sprintf "%ssync all" ind

  | Allocate (name, dims) ->
    (match Hashtbl.find_opt coarray_vars name with
    | None ->
      Printf.sprintf "%sallocate(%s(%s))" ind name
        (String.concat ", " (List.map gen_expr dims))
    | Some n_extra ->
      (* Last n_extra dims are extra codim sizes; remainder are array dims. *)
      let n_total = List.length dims in
      let n_array = n_total - n_extra in
      let array_dims = List.filteri (fun i _ -> i < n_array) dims in
      let codim_sizes = List.filteri (fun i _ -> i >= n_array) dims in
      let array_str = String.concat ", " (List.map gen_expr array_dims) in
      let codim_str =
        if codim_sizes = [] then "*"
        else String.concat ", " (List.map gen_expr codim_sizes) ^ ", *"
      in
      Printf.sprintf "%sallocate(%s(%s)[%s])" ind name array_str codim_str)

  | Pass ->
    Printf.sprintf "%scontinue" ind

and gen_stmts_into buf indent stmts =
  List.iter (fun s ->
    let line = gen_stmt indent s in
    if line <> "" then Buffer.add_string buf (line ^ "\n")
  ) stmts

and gen_lvalue = function
  | Var name -> name
  | Index (e, subs) ->
    let parent = gen_lvalue e in
    let sub_strs =
      List.mapi (fun i sub -> gen_subscript parent (i + 1) sub) subs
    in
    parent ^ "(" ^ String.concat ", " sub_strs ^ ")"
  | CoarrayIndex (e, idxs) ->
    gen_lvalue e ^ "[" ^ String.concat ", " (List.map gen_index_expr idxs) ^ "]"
  | FieldAccess (e, field) ->
    gen_lvalue e ^ "%" ^ field
  | _ -> failwith "Invalid lvalue"

and gen_gpu_kernel_call indent loop : string =
  incr gpu_kernel_counter;
  let kernel_name = Printf.sprintf "fortscriptgpukernel%d" !gpu_kernel_counter in
  let helpers = collect_gpu_kernel_helpers loop in
  let params = make_gpu_kernel_params loop helpers in
  let kernel_body = [For { loop with gpu = false }] in
  let kernel_fd = {
    func_name = kernel_name;
    params;
    return_type = TVoid;
    body = kernel_body;
  } in
  let source = (!gen_procedure_ref) 0 helpers true kernel_fd in
  let filename = kernel_name ^ "_gpu.f90" in
  gpu_kernels := !gpu_kernels @ [{ name = kernel_name; filename; params; body = kernel_body; source }];
  let args_str = String.concat ", " (gpu_actual_args params) in
  let ind = indent_str indent in
  Printf.sprintf "%scall %s(%s)" ind kernel_name args_str

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
  | SyncAll | Allocate _ -> []
  | _ -> []

(* Check if generated body uses the implicit loop variable *)
let body_uses_implicit_loop_var body_str =
  try ignore (Str.search_forward (Str.regexp_string "fortscript_i__") body_str 0); true
  with Not_found -> false

let initialize_proc_context (fd : func_def) =
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
  if is_lapack_qr_stub fd || is_lapack_solve_stub fd || is_lapack_svd_stub fd || is_lapack_eig_stub fd then
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

(* ---- Top-level declarations ---- *)
let gen_struct name fields =
  let buf = Buffer.create 256 in
  Buffer.add_string buf (Printf.sprintf "  type :: %s\n" name);
  List.iter (fun f ->
    Buffer.add_string buf (Printf.sprintf "    %s\n" (fortran_type_decl f.field_name f.field_type))
  ) fields;
  Buffer.add_string buf (Printf.sprintf "  end type %s\n" name);
  Buffer.contents buf

let program_uses_plotting (program : program) =
  let rec expr_uses_plot = function
    | Call (name, args) -> is_plot_builtin name || List.exists expr_uses_plot args
    | BinOp (_, l, r) -> expr_uses_plot l || expr_uses_plot r
    | UnaryOp (_, e) -> expr_uses_plot e
    | Index (e, subs) ->
      expr_uses_plot e || List.exists subscript_uses_plot subs
    | CoarrayIndex (e, idxs) ->
      expr_uses_plot e || List.exists expr_uses_plot idxs
    | FieldAccess (e, _) -> expr_uses_plot e
    | ArrayLit elems -> List.exists expr_uses_plot elems
    | RangeExpr (start_e, stop_e, step_e) ->
      expr_uses_plot start_e ||
      expr_uses_plot stop_e ||
      (match step_e with Some e -> expr_uses_plot e | None -> false)
    | IntLit _ | FloatLit _ | BoolLit _ | StringLit _ | Var _ -> false
  and subscript_uses_plot = function
    | IndexSubscript e -> expr_uses_plot e
    | SliceSubscript (start_e, stop_e, step_e) ->
      (match start_e with Some e -> expr_uses_plot e | None -> false) ||
      (match stop_e with Some e -> expr_uses_plot e | None -> false) ||
      (match step_e with Some e -> expr_uses_plot e | None -> false)
  and stmt_uses_plot = function
    | Assign (target, value) -> expr_uses_plot target || expr_uses_plot value
    | VarDecl (_, _, Some e) -> expr_uses_plot e
    | VarDecl (_, _, None) -> false
    | AugAssign (_, target, value) -> expr_uses_plot target || expr_uses_plot value
    | Return (Some e) -> expr_uses_plot e
    | Return None -> false
    | If { cond; body; elifs; else_body } ->
      expr_uses_plot cond ||
      List.exists stmt_uses_plot body ||
      List.exists (fun (c, b) -> expr_uses_plot c || List.exists stmt_uses_plot b) elifs ||
      List.exists stmt_uses_plot else_body
    | For { start_expr; end_expr; step_expr; for_body; _ } ->
      expr_uses_plot start_expr ||
      expr_uses_plot end_expr ||
      (match step_expr with Some e -> expr_uses_plot e | None -> false) ||
      List.exists stmt_uses_plot for_body
    | While (cond, body) ->
      expr_uses_plot cond || List.exists stmt_uses_plot body
    | ExprStmt e -> expr_uses_plot e
    | Print args -> List.exists expr_uses_plot args
    | SyncAll -> false
    | Allocate (_, dims) -> List.exists expr_uses_plot dims
    | Pass -> false
  in
  List.exists (function
    | FuncDef { body; _ } -> List.exists stmt_uses_plot body
    | GlobalVarDecl (_, _, Some e) -> expr_uses_plot e
    | GlobalVarDecl (_, _, None) | StructDef _ | Import _ -> false
  ) program

(* Walk the program looking for any h5write/h5read call so we can emit the
   `use h5fortran` import only when actually needed. *)
let program_uses_h5 (program : program) =
  let rec expr_uses_h5 = function
    | Call (name, args) -> is_h5_builtin name || List.exists expr_uses_h5 args
    | BinOp (_, l, r) -> expr_uses_h5 l || expr_uses_h5 r
    | UnaryOp (_, e) -> expr_uses_h5 e
    | Index (e, subs) ->
      expr_uses_h5 e || List.exists subscript_uses_h5 subs
    | CoarrayIndex (e, idxs) ->
      expr_uses_h5 e || List.exists expr_uses_h5 idxs
    | FieldAccess (e, _) -> expr_uses_h5 e
    | ArrayLit elems -> List.exists expr_uses_h5 elems
    | RangeExpr (start_e, stop_e, step_e) ->
      expr_uses_h5 start_e ||
      expr_uses_h5 stop_e ||
      (match step_e with Some e -> expr_uses_h5 e | None -> false)
    | IntLit _ | FloatLit _ | BoolLit _ | StringLit _ | Var _ -> false
  and subscript_uses_h5 = function
    | IndexSubscript e -> expr_uses_h5 e
    | SliceSubscript (start_e, stop_e, step_e) ->
      (match start_e with Some e -> expr_uses_h5 e | None -> false) ||
      (match stop_e with Some e -> expr_uses_h5 e | None -> false) ||
      (match step_e with Some e -> expr_uses_h5 e | None -> false)
  and stmt_uses_h5 = function
    | Assign (target, value) -> expr_uses_h5 target || expr_uses_h5 value
    | VarDecl (_, _, Some e) -> expr_uses_h5 e
    | VarDecl (_, _, None) -> false
    | AugAssign (_, target, value) -> expr_uses_h5 target || expr_uses_h5 value
    | Return (Some e) -> expr_uses_h5 e
    | Return None -> false
    | If { cond; body; elifs; else_body } ->
      expr_uses_h5 cond ||
      List.exists stmt_uses_h5 body ||
      List.exists (fun (c, b) -> expr_uses_h5 c || List.exists stmt_uses_h5 b) elifs ||
      List.exists stmt_uses_h5 else_body
    | For { start_expr; end_expr; step_expr; for_body; _ } ->
      expr_uses_h5 start_expr ||
      expr_uses_h5 end_expr ||
      (match step_expr with Some e -> expr_uses_h5 e | None -> false) ||
      List.exists stmt_uses_h5 for_body
    | While (cond, body) ->
      expr_uses_h5 cond || List.exists stmt_uses_h5 body
    | ExprStmt e -> expr_uses_h5 e
    | Print args -> List.exists expr_uses_h5 args
    | SyncAll -> false
    | Allocate (_, dims) -> List.exists expr_uses_h5 dims
    | Pass -> false
  in
  List.exists (function
    | FuncDef { body; _ } -> List.exists stmt_uses_h5 body
    | GlobalVarDecl (_, _, Some e) -> expr_uses_h5 e
    | GlobalVarDecl (_, _, None) | StructDef _ | Import _ -> false
  ) program

let program_uses_lapack_qr (program : program) =
  List.exists (function
    | FuncDef fd -> is_lapack_qr_stub fd
    | _ -> false
  ) program

let program_uses_lapack_svd (program : program) =
  List.exists (function
    | FuncDef fd -> is_lapack_svd_stub fd
    | _ -> false
  ) program

let program_uses_lapack_eig (program : program) =
  List.exists (function
    | FuncDef fd -> is_lapack_eig_stub fd
    | _ -> false
  ) program

let program_uses_lapack_solve (program : program) =
  List.exists (function
    | FuncDef fd -> is_lapack_solve_stub fd
    | _ -> false
  ) program

let program_uses_coarrays (program : program) =
  let rec type_uses_coarrays = function
    | TCoarray _ -> true
    | TArray (elem_t, _) -> type_uses_coarrays elem_t
    | _ -> false
  in
  let add_coarray_name table name typ =
    if type_uses_coarrays typ then Hashtbl.replace table name true
  in
  let rec collect_stmt_coarray_names table = function
    | VarDecl (name, typ, _) -> add_coarray_name table name typ
    | If { body; elifs; else_body; _ } ->
      List.iter (collect_stmt_coarray_names table) body;
      List.iter (fun (_, elif_body) -> List.iter (collect_stmt_coarray_names table) elif_body) elifs;
      List.iter (collect_stmt_coarray_names table) else_body
    | For { for_body; _ } ->
      List.iter (collect_stmt_coarray_names table) for_body
    | While (_, body) ->
      List.iter (collect_stmt_coarray_names table) body
    | Assign _ | AugAssign _ | Return _ | ExprStmt _ | Print _
    | SyncAll | Allocate _ | Pass -> ()
  in
  let rec expr_uses_coarrays = function
    | CoarrayIndex (target_e, idxs) ->
      let _ = expr_uses_coarrays target_e in
      let _ = List.exists expr_uses_coarrays idxs in
      true
    | Call (("this_image" | "num_images"), args) ->
      let _ = List.exists expr_uses_coarrays args in
      true
    | Call (_, args) -> List.exists expr_uses_coarrays args
    | BinOp (_, l, r) -> expr_uses_coarrays l || expr_uses_coarrays r
    | UnaryOp (_, e) -> expr_uses_coarrays e
    | Index (e, subs) ->
      expr_uses_coarrays e || List.exists subscript_uses_coarrays subs
    | FieldAccess (e, _) -> expr_uses_coarrays e
    | ArrayLit elems -> List.exists expr_uses_coarrays elems
    | RangeExpr (start_e, stop_e, step_e) ->
      expr_uses_coarrays start_e ||
      expr_uses_coarrays stop_e ||
      (match step_e with Some e -> expr_uses_coarrays e | None -> false)
    | IntLit _ | FloatLit _ | BoolLit _ | StringLit _ | Var _ -> false
  and subscript_uses_coarrays = function
    | IndexSubscript e -> expr_uses_coarrays e
    | SliceSubscript (start_e, stop_e, step_e) ->
      (match start_e with Some e -> expr_uses_coarrays e | None -> false) ||
      (match stop_e with Some e -> expr_uses_coarrays e | None -> false) ||
      (match step_e with Some e -> expr_uses_coarrays e | None -> false)
  and stmt_uses_coarrays coarray_names = function
    | Assign (target, value) -> expr_uses_coarrays target || expr_uses_coarrays value
    | VarDecl (_, typ, init) ->
      type_uses_coarrays typ ||
      (match init with Some e -> expr_uses_coarrays e | None -> false)
    | AugAssign (_, target, value) -> expr_uses_coarrays target || expr_uses_coarrays value
    | Return (Some e) -> expr_uses_coarrays e
    | Return None -> false
    | If { cond; body; elifs; else_body } ->
      expr_uses_coarrays cond ||
      List.exists (stmt_uses_coarrays coarray_names) body ||
      List.exists (fun (elif_cond, elif_body) ->
        expr_uses_coarrays elif_cond || List.exists (stmt_uses_coarrays coarray_names) elif_body
      ) elifs ||
      List.exists (stmt_uses_coarrays coarray_names) else_body
    | For { start_expr; end_expr; step_expr; for_body; _ } ->
      expr_uses_coarrays start_expr ||
      expr_uses_coarrays end_expr ||
      (match step_expr with Some e -> expr_uses_coarrays e | None -> false) ||
      List.exists (stmt_uses_coarrays coarray_names) for_body
    | While (cond, body) ->
      expr_uses_coarrays cond || List.exists (stmt_uses_coarrays coarray_names) body
    | ExprStmt e -> expr_uses_coarrays e
    | Print args -> List.exists expr_uses_coarrays args
    | SyncAll -> true
    | Allocate (name, dims) ->
      Hashtbl.mem coarray_names name || List.exists expr_uses_coarrays dims
    | Pass -> false
  in
  let global_coarray_names = Hashtbl.create 16 in
  List.iter (function
    | GlobalVarDecl (name, typ, _) -> add_coarray_name global_coarray_names name typ
    | _ -> ()
  ) program;
  List.exists (function
    | Import _ -> false
    | StructDef (_, fields) ->
      List.exists (fun field -> type_uses_coarrays field.field_type) fields
    | FuncDef fd ->
      let coarray_names = Hashtbl.copy global_coarray_names in
      List.iter (fun param -> add_coarray_name coarray_names param.param_name param.param_type) fd.params;
      List.iter (collect_stmt_coarray_names coarray_names) fd.body;
      List.exists (fun param -> type_uses_coarrays param.param_type) fd.params ||
      type_uses_coarrays fd.return_type ||
      List.exists (stmt_uses_coarrays coarray_names) fd.body
    | GlobalVarDecl (_, typ, init) ->
      type_uses_coarrays typ ||
      (match init with Some e -> expr_uses_coarrays e | None -> false)
  ) program

let gen_function fd =
  gen_procedure fd

let generate_output (program : program) : generated_output =
  let buf = Buffer.create 4096 in
  let uses_plotting = program_uses_plotting program in
  let uses_h5 = program_uses_h5 program in
  let uses_lapack_qr = program_uses_lapack_qr program in
  let uses_lapack_solve = program_uses_lapack_solve program in
  let uses_lapack_svd = program_uses_lapack_svd program in
  let uses_lapack_eig = program_uses_lapack_eig program in
  let uses_coarrays = program_uses_coarrays program in
  let callable_types = collect_callable_types program in

  (* Register user-defined functions *)
  Hashtbl.clear user_functions;
  Hashtbl.clear callable_interfaces;
  Hashtbl.clear global_coarray_vars;
  Hashtbl.clear global_var_types;
  gpu_kernels := [];
  gpu_kernel_counter := 0;
  parallel_feature_counter := 0;
  current_proc_name := None;
  lapack_qr_enabled := uses_lapack_qr;
  lapack_solve_enabled := uses_lapack_solve;
  lapack_svd_enabled := uses_lapack_svd;
  lapack_eig_enabled := uses_lapack_eig;
  coarrays_enabled := uses_coarrays;
  List.iteri (fun idx typ ->
    Hashtbl.replace callable_interfaces
      (callable_type_key typ) (Printf.sprintf "fortscript_callable_%d__" (idx + 1))
  ) callable_types;
  List.iter (fun d ->
    match d with
    | FuncDef fd -> Hashtbl.add user_functions fd.func_name fd
    | GlobalVarDecl (name, typ, _) ->
      Hashtbl.replace global_var_types name typ;
      (match typ with
       | TCoarray (_, extra) -> Hashtbl.replace global_coarray_vars name (List.length extra)
       | _ -> ())
    | _ -> ()
  ) program;

  (* Compute which functions need 'pure' qualifier *)
  compute_pure_functions program;

  Buffer.add_string buf "module fortscript_mod\n";
  (* Pull in h5fortran's high-level h5write/h5read at module scope so all
     contained subroutines see them via host association. *)
  if uses_h5 then
    Buffer.add_string buf "  use h5fortran, only: h5write, h5read\n";
  Buffer.add_string buf "  implicit none\n\n";

  (* Struct type definitions *)
  let structs = List.filter_map (fun d ->
    match d with StructDef (name, fields) -> Some (name, fields) | _ -> None
  ) program in
  List.iter (fun (name, fields) ->
    Buffer.add_string buf (gen_struct name fields);
    Buffer.add_string buf "\n"
  ) structs;

  List.iter (fun typ ->
    Buffer.add_string buf (gen_callable_interface typ);
    Buffer.add_string buf "\n"
  ) callable_types;

  (* Global variables *)
  let globals = List.filter_map (fun d ->
    match d with GlobalVarDecl (name, typ, init) -> Some (name, typ, init) | _ -> None
  ) program in
  if globals <> [] then begin
    List.iter (fun (name, typ, _) ->
      Buffer.add_string buf (Printf.sprintf "  %s\n" (fortran_type_decl name typ))
    ) globals;
    Buffer.add_string buf "\n"
  end;

  (* Functions in 'contains' *)
  let funcs = List.filter_map (fun d ->
    match d with FuncDef fd -> Some fd | _ -> None
  ) program in
  let generated_funcs =
    List.filter_map (fun fd ->
      let generated = gen_function fd in
      if generated = "" then None else Some generated
    ) funcs
  in
  if !gpu_kernels <> [] then begin
    List.iter (fun kernel ->
      Buffer.add_string buf (gen_gpu_interface kernel.name kernel.params kernel.body);
      Buffer.add_string buf "\n"
    ) !gpu_kernels
  end;
  if funcs <> [] || uses_plotting || uses_lapack_qr || uses_lapack_solve || uses_lapack_svd || uses_lapack_eig then begin
    Buffer.add_string buf "contains\n\n";
    if uses_plotting then begin
      Buffer.add_string buf (gen_plot_helper ());
      Buffer.add_string buf "\n";
      Buffer.add_string buf (gen_histogram_helper ());
      Buffer.add_string buf "\n";
      Buffer.add_string buf (gen_scatter_helper ());
      Buffer.add_string buf "\n";
      Buffer.add_string buf (gen_imshow_helper ());
      Buffer.add_string buf "\n";
      Buffer.add_string buf (gen_contour_helper ());
      Buffer.add_string buf "\n"
    end;
    if uses_lapack_qr then begin
      Buffer.add_string buf (gen_lapack_qr_helper ());
      Buffer.add_string buf "\n"
    end;
    if uses_lapack_solve then begin
      Buffer.add_string buf (gen_lapack_solve_helper ());
      Buffer.add_string buf "\n"
    end;
    if uses_lapack_svd then begin
      Buffer.add_string buf (gen_lapack_svd_helper ());
      Buffer.add_string buf "\n"
    end;
    if uses_lapack_eig then begin
      Buffer.add_string buf (gen_lapack_eig_helper ());
      Buffer.add_string buf "\n"
    end;
    List.iter (fun generated ->
      Buffer.add_string buf generated;
      Buffer.add_string buf "\n"
    ) generated_funcs
  end;

  Buffer.add_string buf "end module fortscript_mod\n\n";

  (* Main program *)
  let has_main = List.exists (fun fd -> fd.func_name = "main") funcs in
  if has_main then begin
    Buffer.add_string buf "program fortscript_main\n";
    Buffer.add_string buf "  use fortscript_mod\n";
    Buffer.add_string buf "  implicit none\n";
    Buffer.add_string buf "  call main()\n";
    Buffer.add_string buf "end program fortscript_main\n"
  end;

  let main_source = Buffer.contents buf in
  {
    main_source;
    gpu_kernels = !gpu_kernels;
  }

let generate (program : program) : string =
  (generate_output program).main_source

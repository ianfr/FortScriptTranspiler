open Ast
open Codegen_state
open Codegen_types

(* Whole-program walks that determine which support helpers must be emitted,
   plus the struct-type emitter. *)

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
    | FString parts -> List.exists (fun p -> match p with FStrExpr (e, _) -> expr_uses_plot e | FStrLit _ -> false) parts
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
    | Break -> false
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
    | FString parts -> List.exists (fun p -> match p with FStrExpr (e, _) -> expr_uses_h5 e | FStrLit _ -> false) parts
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
    | Break -> false
    | Pass -> false
  in
  List.exists (function
    | FuncDef { body; _ } -> List.exists stmt_uses_h5 body
    | GlobalVarDecl (_, _, Some e) -> expr_uses_h5 e
    | GlobalVarDecl (_, _, None) | StructDef _ | Import _ -> false
  ) program

let program_uses_xdmf (program : program) =
  let rec expr_uses_xdmf = function
    | Call (name, args) -> is_xdmf_builtin name || List.exists expr_uses_xdmf args
    | BinOp (_, l, r) -> expr_uses_xdmf l || expr_uses_xdmf r
    | UnaryOp (_, e) -> expr_uses_xdmf e
    | Index (e, subs) ->
      expr_uses_xdmf e || List.exists subscript_uses_xdmf subs
    | CoarrayIndex (e, idxs) ->
      expr_uses_xdmf e || List.exists expr_uses_xdmf idxs
    | FieldAccess (e, _) -> expr_uses_xdmf e
    | ArrayLit elems -> List.exists expr_uses_xdmf elems
    | RangeExpr (start_e, stop_e, step_e) ->
      expr_uses_xdmf start_e ||
      expr_uses_xdmf stop_e ||
      (match step_e with Some e -> expr_uses_xdmf e | None -> false)
    | FString parts -> List.exists (fun p -> match p with FStrExpr (e, _) -> expr_uses_xdmf e | FStrLit _ -> false) parts
    | IntLit _ | FloatLit _ | BoolLit _ | StringLit _ | Var _ -> false
  and subscript_uses_xdmf = function
    | IndexSubscript e -> expr_uses_xdmf e
    | SliceSubscript (start_e, stop_e, step_e) ->
      (match start_e with Some e -> expr_uses_xdmf e | None -> false) ||
      (match stop_e with Some e -> expr_uses_xdmf e | None -> false) ||
      (match step_e with Some e -> expr_uses_xdmf e | None -> false)
  and stmt_uses_xdmf = function
    | Assign (target, value) -> expr_uses_xdmf target || expr_uses_xdmf value
    | VarDecl (_, _, Some e) -> expr_uses_xdmf e
    | VarDecl (_, _, None) -> false
    | AugAssign (_, target, value) -> expr_uses_xdmf target || expr_uses_xdmf value
    | Return (Some e) -> expr_uses_xdmf e
    | Return None -> false
    | If { cond; body; elifs; else_body } ->
      expr_uses_xdmf cond ||
      List.exists stmt_uses_xdmf body ||
      List.exists (fun (c, b) -> expr_uses_xdmf c || List.exists stmt_uses_xdmf b) elifs ||
      List.exists stmt_uses_xdmf else_body
    | For { start_expr; end_expr; step_expr; for_body; _ } ->
      expr_uses_xdmf start_expr ||
      expr_uses_xdmf end_expr ||
      (match step_expr with Some e -> expr_uses_xdmf e | None -> false) ||
      List.exists stmt_uses_xdmf for_body
    | While (cond, body) ->
      expr_uses_xdmf cond || List.exists stmt_uses_xdmf body
    | ExprStmt e -> expr_uses_xdmf e
    | Print args -> List.exists expr_uses_xdmf args
    | SyncAll -> false
    | Allocate (_, dims) -> List.exists expr_uses_xdmf dims
    | Break -> false
    | Pass -> false
  in
  List.exists (function
    | FuncDef { body; _ } -> List.exists stmt_uses_xdmf body
    | GlobalVarDecl (_, _, Some e) -> expr_uses_xdmf e
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

let program_uses_random_fill (program : program) =
  List.exists (function
    | FuncDef fd -> is_random_fill_stub fd
    | _ -> false
  ) program

let program_uses_uniform_fill (program : program) =
  List.exists (function
    | FuncDef fd -> is_uniform_fill_stub fd
    | _ -> false
  ) program

let program_uses_random_seed (program : program) =
  List.exists (function
    | FuncDef fd -> is_random_seed_stub fd
    | _ -> false
  ) program

let program_uses_prand_uniform (program : program) =
  List.exists (function
    | FuncDef fd -> is_prand_uniform_stub fd
    | _ -> false
  ) program

let program_uses_prand_uniform_thread (program : program) =
  List.exists (function
    | FuncDef fd -> is_prand_uniform_thread_stub fd
    | _ -> false
  ) program

let program_uses_prand_seed_parallel (program : program) =
  List.exists (function
    | FuncDef fd -> is_prand_seed_parallel_stub fd
    | _ -> false
  ) program

let program_uses_geom_stl_ascii (program : program) =
  List.exists (function
    | FuncDef fd -> is_geom_stl_read_ascii_stub fd
    | _ -> false
  ) program

let program_uses_geom_stl_binary (program : program) =
  List.exists (function
    | FuncDef fd -> is_geom_stl_read_binary_stub fd
    | _ -> false
  ) program

(* ---- Generic-type instantiation collection (CartesianMesh[T] and friends) ----
   Walk the program looking for any TGeneric type used in a variable or
   parameter declaration. Return the set of distinct (base_name, args) pairs
   in source order. *)
let collect_generic_instantiations (program : program) : (string * typ list) list =
  let seen : (string, unit) Hashtbl.t = Hashtbl.create 8 in
  let acc : (string * typ list) list ref = ref [] in
  let key base args =
    base ^ "<" ^ String.concat "," (List.map (function
      | TStruct n -> n
      | _ -> "?") args) ^ ">"
  in
  let record base args =
    let k = key base args in
    if not (Hashtbl.mem seen k) then begin
      Hashtbl.add seen k ();
      acc := (base, args) :: !acc
    end
  in
  let rec walk_typ = function
    | TGeneric (base, args) ->
      record base args;
      List.iter walk_typ args
    | TArray (elem_t, _) -> walk_typ elem_t
    | TCoarray (elem_t, _) -> walk_typ elem_t
    | TFunc (params, ret) ->
      List.iter walk_typ params; walk_typ ret
    | _ -> ()
  in
  let rec walk_stmt = function
    | VarDecl (_, t, _) -> walk_typ t
    | If { body; elifs; else_body; _ } ->
      List.iter walk_stmt body;
      List.iter (fun (_, b) -> List.iter walk_stmt b) elifs;
      List.iter walk_stmt else_body
    | For { for_body; _ } -> List.iter walk_stmt for_body
    | While (_, body) -> List.iter walk_stmt body
    | _ -> ()
  in
  List.iter (function
    | FuncDef fd ->
      List.iter (fun p -> walk_typ p.param_type) fd.params;
      walk_typ fd.return_type;
      List.iter walk_stmt fd.body
    | GlobalVarDecl (_, t, _) -> walk_typ t
    | StructDef (_, fields) ->
      List.iter (fun f -> walk_typ f.field_type) fields
    | Import _ -> ()
  ) program;
  List.rev !acc

(* Emit a Fortran derived type that extends the base struct (assumed already
   emitted) and adds one allocatable per field of the type-parameter struct.
   Scalar float fields become rank-1 cell arrays; 3-vector float fields become
   rank-2 arrays indexed by cell then component. Other field types are skipped
   with a comment. *)
let gen_generic_instantiation (base : string) (args : typ list)
                              (struct_defs : (string * struct_field list) list) : string =
  let buf = Buffer.create 256 in
  let mono = monomorphized_type_name base args in
  Buffer.add_string buf (Printf.sprintf "  type, extends(%s) :: %s\n"
    (String.lowercase_ascii base) mono);
  List.iter (fun arg ->
    match arg with
    | TStruct arg_name ->
      (match List.assoc_opt arg_name struct_defs with
       | Some fields ->
         List.iter (fun f ->
           match f.field_type with
           | TFloat ->
             Buffer.add_string buf
               (Printf.sprintf "    real(8), allocatable :: %s(:)\n" f.field_name)
           | TArray (TFloat, [FixedDim (IntLit 3)]) ->
             Buffer.add_string buf
               (Printf.sprintf "    real(8), allocatable :: %s(:,:)\n" f.field_name)
           | _ ->
             Buffer.add_string buf
               (Printf.sprintf "    ! field %s skipped (only float and array[float,3] supported)\n" f.field_name)
         ) fields
       | None -> ())
    | _ -> ()
  ) args;
  Buffer.add_string buf (Printf.sprintf "  end type %s\n" mono);
  Buffer.contents buf

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
    | SyncAll | Allocate _ | Break | Pass -> ()
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
    | FString parts -> List.exists (fun p -> match p with FStrExpr (e, _) -> expr_uses_coarrays e | FStrLit _ -> false) parts
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
    | Break -> false
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

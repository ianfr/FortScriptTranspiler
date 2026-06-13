open Ast
open Codegen_state
open Codegen_types

(* Expression codegen and per-builtin standalone-statement emitters. *)

(* ---- Expression codegen ---- *)
let rec gen_expr = function
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
  | FString parts ->
    let pieces = List.filter_map (fun part ->
      match part with
      | FStrLit "" -> None
      | FStrLit s  -> Some ("\"" ^ s ^ "\"")
      | FStrExpr (e, fmt) ->
        incr fstr_tmp_counter;
        let idx = !fstr_tmp_counter in
        if idx > !fstr_max_index then fstr_max_index := idx;
        let fmt_str = match fmt with
          | None   -> "'(g0)'"
          | Some n -> Printf.sprintf "'(f0.%d)'" n
        in
        fstr_prestmts := Printf.sprintf "write(fortscript_fstr_tmp_%d__, %s) %s" idx fmt_str (gen_expr e) :: !fstr_prestmts;
        Some (Printf.sprintf "trim(adjustl(fortscript_fstr_tmp_%d__))" idx)
    ) parts in
    (match pieces with
     | []  -> "\"\""
     | _   -> String.concat " // " pieces)
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
  else if is_xdmf_builtin name then
    failwith (name ^ "() can only be used as a standalone statement")
  else if name = "append" then
    failwith "append() can only be used as a standalone statement"
  else if name = "geom_cartesian_face_neighbor_kind" then
    match lowered_args with
    | [mesh_e; c_e; face_e] ->
      let m = gen_expr mesh_e in
      let c = gen_index_expr c_e in
      let face = gen_index_expr face_e in
      let n = Printf.sprintf "max(1, %s%%neighbor(%s, %s, 1) + 1)" m c face in
      Printf.sprintf
        "merge(3, merge(1, merge(2, 0, %s%%level(%s) > %s%%level(%s)), %s%%level(%s) < %s%%level(%s)), %s%%neighbor(%s, %s, 1) < 0)"
        m n m c m n m c m c face
    | _ -> failwith "geom_cartesian_face_neighbor_kind() expects 3 arguments"
  else if !lapack_qr_enabled && name = "qr" then
    failwith "qr() can only be used as a standalone statement"
  else if !lapack_solve_enabled && name = "solve" then
    failwith "solve() can only be used as a standalone statement"
  else if !lapack_svd_enabled && name = "svd" then
    failwith "svd() can only be used as a standalone statement"
  else if !lapack_eig_enabled && name = "eig" then
    failwith "eig() can only be used as a standalone statement"
  else if !random_fill_enabled && name = "random_fill" then
    failwith "random_fill() can only be used as a standalone statement"
  else if !uniform_fill_enabled && name = "uniform_fill" then
    failwith "uniform_fill() can only be used as a standalone statement"
  else if !random_seed_enabled && name = "seed" then
    failwith "seed() can only be used as a standalone statement"
  else if !prand_uniform_enabled && name = "prand_uniform" then
    "fortscript_prand_uniform__()"
  else if !prand_uniform_thread_enabled && name = "prand_uniform_thread" then
    "fortscript_prand_uniform_thread__()"
  else if !prand_seed_parallel_enabled && name = "prand_seed_parallel" then
    failwith "prand_seed_parallel() can only be used as a standalone statement"
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
    (* No title, no axis labels *)
    Printf.sprintf "%scall fortscript_imshow__(%s, %s, \"\", \"\", \"\")"
      ind (gen_expr z_e) (gen_expr file_e)
  | [z_e; file_e; title_e] ->
    (* Title only *)
    Printf.sprintf "%scall fortscript_imshow__(%s, %s, %s, \"\", \"\")"
      ind (gen_expr z_e) (gen_expr file_e) (gen_expr title_e)
  | [z_e; file_e; title_e; xlabel_e; ylabel_e] ->
    (* Title plus x and y axis labels *)
    Printf.sprintf "%scall fortscript_imshow__(%s, %s, %s, %s, %s)"
      ind (gen_expr z_e) (gen_expr file_e) (gen_expr title_e) (gen_expr xlabel_e) (gen_expr ylabel_e)
  | _ ->
    failwith "imshow() expects 2, 3, or 5 arguments"

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

let gen_xdmf_stmt indent name args =
  let ind = indent_str indent in
  match name, args with
  | "xdmf_add", [xml_e; field_name_e; field_array_e] ->
    Printf.sprintf "%scall fortscript_xdmf_add__(%s, %s, %s)"
      ind (gen_expr xml_e) (gen_expr field_name_e) (gen_expr field_array_e)
  | "xdmf_add_xyz", [xml_e; x_e; y_e; z_e] ->
    Printf.sprintf "%scall fortscript_xdmf_add_xyz__(%s, %s, %s, %s)"
      ind (gen_expr xml_e) (gen_expr x_e) (gen_expr y_e) (gen_expr z_e)
  | "xdmf_add_unstructured", [xml_e; points_e; conn_e] ->
    Printf.sprintf "%scall fortscript_xdmf_add_unstructured__(%s, %s, %s)"
      ind (gen_expr xml_e) (gen_expr points_e) (gen_expr conn_e)
  | "xdmf_add_cell", [xml_e; field_name_e; field_array_e] ->
    Printf.sprintf "%scall fortscript_xdmf_add_cell__(%s, %s, %s)"
      ind (gen_expr xml_e) (gen_expr field_name_e) (gen_expr field_array_e)
  | "xdmf_write", [xdmf_file_e; h5_file_e; xml_e] ->
    Printf.sprintf "%scall fortscript_xdmf_write__(%s, %s, %s)"
      ind (gen_expr xdmf_file_e) (gen_expr h5_file_e) (gen_expr xml_e)
  | "xdmf_add", _ ->
    failwith "xdmf_add() expects 3 arguments: xml_str, field_name, field_array"
  | "xdmf_add_xyz", _ ->
    failwith "xdmf_add_xyz() expects 4 arguments: xml_str, x, y, z"
  | "xdmf_add_unstructured", _ ->
    failwith "xdmf_add_unstructured() expects 3 arguments: xml_str, points, connectivity"
  | "xdmf_add_cell", _ ->
    failwith "xdmf_add_cell() expects 3 arguments: xml_str, field_name, field_array"
  | "xdmf_write", _ ->
    failwith "xdmf_write() expects 3 arguments: xdmf_filename, h5_filename, xml_str"
  | _ ->
    failwith ("Unknown XDMF builtin: " ^ name)

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

let gen_random_fill_stmt indent args =
  let ind = indent_str indent in
  match args with
  | [x_e] ->
    Printf.sprintf "%scall fortscript_random_fill__(%s)" ind (gen_expr x_e)
  | _ ->
    failwith "random_fill() expects 1 argument: x"

let gen_uniform_fill_stmt indent args =
  let ind = indent_str indent in
  match args with
  | [low_e; high_e; x_e] ->
    Printf.sprintf "%scall fortscript_uniform_fill__(%s, %s, %s)"
      ind (gen_expr low_e) (gen_expr high_e) (gen_expr x_e)
  | _ ->
    failwith "uniform_fill() expects 3 arguments: low, high, x"

let gen_random_seed_stmt indent args =
  let ind = indent_str indent in
  match args with
  | [s_e] ->
    Printf.sprintf "%scall fortscript_random_seed__(%s)" ind (gen_expr s_e)
  | _ ->
    failwith "seed() expects 1 argument: s"

let gen_prand_seed_parallel_stmt indent args =
  let ind = indent_str indent in
  match args with
  | [s_e] ->
    Printf.sprintf "%scall fortscript_prand_seed_parallel__(%s)" ind (gen_expr s_e)
  | _ ->
    failwith "prand_seed_parallel() expects 1 argument: s"

let gen_append_stmt indent args =
  let ind = indent_str indent in
  match args with
  | [Var arr; value_e] ->
    let elem_t =
      match Hashtbl.find_opt current_var_types arr with
      | Some (TArray (elem_t, [DeferredDim])) -> elem_t
      | Some _ -> failwith "append() expects a 1D deferred-shape array"
      | None ->
        (match Hashtbl.find_opt global_var_types arr with
         | Some (TArray (elem_t, [DeferredDim])) -> elem_t
         | Some _ -> failwith "append() expects a 1D deferred-shape array"
         | None -> failwith ("Cannot resolve type of append target " ^ arr))
    in
    (match elem_t with
     | TString | TArray _ | TCoarray _ | TFunc _ | TVoid ->
       failwith "append() target element type is not supported"
     | _ -> ());
    let tmp = "fortscript_append_tmp__" in
    String.concat "\n" [
      Printf.sprintf "%sblock" ind;
      Printf.sprintf "%s  %s, allocatable :: %s(:)" ind (fortran_base_type elem_t) tmp;
      Printf.sprintf "%s  if (allocated(%s)) then" ind arr;
      Printf.sprintf "%s    allocate(%s(size(%s) + 1))" ind tmp arr;
      Printf.sprintf "%s    if (size(%s) > 0) %s(1:size(%s)) = %s" ind arr tmp arr arr;
      Printf.sprintf "%s    %s(size(%s) + 1) = %s" ind tmp arr (gen_expr value_e);
      Printf.sprintf "%s    call move_alloc(%s, %s)" ind tmp arr;
      Printf.sprintf "%s  else" ind;
      Printf.sprintf "%s    allocate(%s(1))" ind arr;
      Printf.sprintf "%s    %s(1) = %s" ind arr (gen_expr value_e);
      Printf.sprintf "%s  end if" ind;
      Printf.sprintf "%send block" ind;
    ]
  | [_; _] ->
    failwith "append() target must be a bare array variable"
  | _ ->
    failwith "append() expects 2 arguments: array, value"

(* Lower geom_stl_read_ascii(filename, mesh) to a call that unpacks the
   STLMesh struct fields into the hand-written Fortran reader subroutine. *)
let gen_geom_stl_read_ascii_stmt indent args =
  let ind = indent_str indent in
  match args with
  | [name_e; mesh_e] ->
    let n = gen_expr name_e in
    let m = gen_expr mesh_e in
    Printf.sprintf
      "%scall fortscript_geom_stl_read_ascii__(%s, %s%%num_triangles, \
%s%%normal_x, %s%%normal_y, %s%%normal_z, \
%s%%v0_x, %s%%v0_y, %s%%v0_z, \
%s%%v1_x, %s%%v1_y, %s%%v1_z, \
%s%%v2_x, %s%%v2_y, %s%%v2_z)"
      ind n m m m m m m m m m m m m m
  | _ ->
    failwith "geom_stl_read_ascii() expects 2 arguments: filename, mesh"

let gen_fvm_equation_init_stmt indent args =
  let ind = indent_str indent in
  match args with
  | [eq_e; mesh_e] ->
    let eq = gen_expr eq_e in
    let mesh = gen_expr mesh_e in
    String.concat "\n" [
      Printf.sprintf "%s%s%%n_rows = %s%%cell_capacity" ind eq mesh;
      Printf.sprintf "%sif (allocated(%s%%diag)) deallocate(%s%%diag)" ind eq eq;
      Printf.sprintf "%sif (allocated(%s%%offdiag)) deallocate(%s%%offdiag)" ind eq eq;
      Printf.sprintf "%sif (allocated(%s%%rhs)) deallocate(%s%%rhs)" ind eq eq;
      Printf.sprintf "%sallocate(%s%%diag(%s%%cell_capacity))" ind eq mesh;
      Printf.sprintf "%sallocate(%s%%offdiag(%s%%cell_capacity, 6, 4))" ind eq mesh;
      Printf.sprintf "%sallocate(%s%%rhs(%s%%cell_capacity))" ind eq mesh;
      Printf.sprintf "%s%s%%diag = 0.0d0" ind eq;
      Printf.sprintf "%s%s%%offdiag = 0.0d0" ind eq;
      Printf.sprintf "%s%s%%rhs = 0.0d0" ind eq;
    ]
  | _ -> failwith "fvm_equation_init() expects 2 arguments"

let gen_geom_stl_read_binary_stmt indent args =
  let ind = indent_str indent in
  match args with
  | [name_e; mesh_e] ->
    let n = gen_expr name_e in
    let m = gen_expr mesh_e in
    Printf.sprintf
      "%scall fortscript_geom_stl_read_binary__(%s, %s%%num_triangles, \
%s%%normal_x, %s%%normal_y, %s%%normal_z, \
%s%%v0_x, %s%%v0_y, %s%%v0_z, \
%s%%v1_x, %s%%v1_y, %s%%v1_z, \
%s%%v2_x, %s%%v2_y, %s%%v2_z)"
      ind n m m m m m m m m m m m m m
  | _ ->
    failwith "geom_stl_read_binary() expects 2 arguments: filename, mesh"

(* Wire up the forward reference so Codegen_types.gen_index_expr/gen_subscript
   etc. can call back into gen_expr at runtime. *)
let () = gen_expr_ref := gen_expr

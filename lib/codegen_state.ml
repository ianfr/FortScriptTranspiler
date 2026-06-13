open Ast

(* Shared mutable state, builtin name tables, simple predicates, stdlib stub
   detectors, and the forward-reference function thunks that bridge the
   codegen layers below.

   This module is opened by every other Codegen_* module. *)

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
(* XDMF sidecar helpers for ParaView-oriented metadata. *)
let xdmf_builtins = ["xdmf_add"; "xdmf_add_xyz"; "xdmf_add_unstructured"; "xdmf_add_cell"; "xdmf_write"]
let is_xdmf_builtin name = List.mem name xdmf_builtins

(* Coarray collective subroutines: must be used as statements, not expressions. *)
let coarray_collectives = ["co_sum"; "co_min"; "co_max"; "co_broadcast"; "co_reduce"]
let is_coarray_collective name = List.mem name coarray_collectives
let lapack_qr_enabled = ref false  (* Tracks whether support.linalg.qr should lower to LAPACK. *)
let lapack_solve_enabled = ref false  (* Tracks whether support.linalg.solve should lower to LAPACK. *)
let lapack_svd_enabled = ref false  (* Tracks whether support.linalg.svd should lower to LAPACK. *)
let lapack_eig_enabled = ref false  (* Tracks whether support.linalg.eig should lower to LAPACK. *)
let random_fill_enabled = ref false  (* Tracks support.random.random_fill lowering. *)
let uniform_fill_enabled = ref false  (* Tracks support.random.uniform_fill lowering. *)
let random_seed_enabled = ref false  (* Tracks support.random.seed lowering. *)
let prand_uniform_enabled = ref false  (* Tracks support.random.prand_uniform lowering. *)
let prand_uniform_thread_enabled = ref false  (* Tracks support.random.prand_uniform_thread lowering. *)
let prand_seed_parallel_enabled = ref false  (* Tracks support.random.prand_seed_parallel lowering. *)
let geom_stl_ascii_enabled = ref false  (* Tracks support.geom_stl.geom_stl_read_ascii lowering. *)
let geom_stl_binary_enabled = ref false  (* Tracks support.geom_stl.geom_stl_read_binary lowering. *)
let coarrays_enabled = ref false  (* Tracks whether the program uses coarrays. *)

(* F-string temporary variable state; reset per procedure. *)
let fstr_tmp_counter = ref 0   (* next unique temp index to allocate *)
let fstr_max_index = ref 0     (* highest index used in current procedure *)
let fstr_prestmts : string list ref = ref []  (* write stmts to prepend to current stmt *)

let is_two_dim_float_array = function
  | TArray (TFloat, [DeferredDim; DeferredDim]) -> true
  | _ -> false

let is_one_dim_float_array = function
  | TArray (TFloat, [DeferredDim]) -> true
  | _ -> false

let is_int_type = function
  | TInt -> true
  | _ -> false

let is_float_type = function
  | TFloat -> true
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

let is_random_fill_stub fd =
  fd.func_name = "random_fill" &&
  fd.return_type = TVoid &&
  List.length fd.params = 1 &&
  (match fd.params with
   | [x_param] -> is_one_dim_float_array x_param.param_type
   | _ -> false) &&
  fd.body = [Pass]

let is_uniform_fill_stub fd =
  fd.func_name = "uniform_fill" &&
  fd.return_type = TVoid &&
  List.length fd.params = 3 &&
  (match fd.params with
   | [low_param; high_param; x_param] ->
     is_float_type low_param.param_type &&
     is_float_type high_param.param_type &&
     is_one_dim_float_array x_param.param_type
   | _ -> false) &&
  fd.body = [Pass]

let is_random_seed_stub fd =
  fd.func_name = "seed" &&
  fd.return_type = TVoid &&
  List.length fd.params = 1 &&
  (match fd.params with
   | [s_param] -> is_int_type s_param.param_type
   | _ -> false) &&
  fd.body = [Pass]

(* Detect the support.random.prand_uniform stub: no args, returns float. *)
let is_prand_uniform_stub fd =
  fd.func_name = "prand_uniform" &&
  fd.return_type = TFloat &&
  List.length fd.params = 0 &&
  fd.body = [Pass]

(* Detect the support.random.prand_uniform_thread stub: no args, returns float. *)
let is_prand_uniform_thread_stub fd =
  fd.func_name = "prand_uniform_thread" &&
  fd.return_type = TFloat &&
  List.length fd.params = 0 &&
  fd.body = [Pass]

(* Detect the support.random.prand_seed_parallel stub: a single int. *)
let is_prand_seed_parallel_stub fd =
  fd.func_name = "prand_seed_parallel" &&
  fd.return_type = TVoid &&
  List.length fd.params = 1 &&
  (match fd.params with
   | [s_param] -> is_int_type s_param.param_type
   | _ -> false) &&
  fd.body = [Pass]

(* Detect the support.geom_stl.geom_stl_read_ascii / _binary stubs:
   signature is (filename: string, mesh: STLMesh) with body [Pass]. *)
let is_geom_stl_read_ascii_stub fd =
  fd.func_name = "geom_stl_read_ascii" &&
  fd.return_type = TVoid &&
  List.length fd.params = 2 &&
  (match fd.params with
   | [name_param; mesh_param] ->
     name_param.param_type = TString &&
     mesh_param.param_type = TStruct "STLMesh"
   | _ -> false) &&
  fd.body = [Pass]

let is_geom_stl_read_binary_stub fd =
  fd.func_name = "geom_stl_read_binary" &&
  fd.return_type = TVoid &&
  List.length fd.params = 2 &&
  (match fd.params with
   | [name_param; mesh_param] ->
     name_param.param_type = TString &&
     mesh_param.param_type = TStruct "STLMesh"
   | _ -> false) &&
  fd.body = [Pass]

(* Geom-cartesian built-in family: lowered by the compiler so that string
   field-name arguments can resolve at compile time against the mesh's
   TGeneric type-parameter struct. *)
(* Compiler-lowered built-ins for the templated CartesianMesh[T] API. Reads
   and writes of individual fields use direct field access (mesh.<name>);
   these built-ins handle generated cell-list allocation and small topology
   helpers that need to accept any CartesianMesh[T] instantiation. *)
let geom_cartesian_builtins = [
  "geom_cartesian_uniform";
  "geom_cartesian_refine_cell";
  "geom_cartesian_refine_to_sdf";
  "geom_cartesian_refine_band";
  "geom_cartesian_coarsen_cell";
  "geom_cartesian_face_neighbor_kind";
  "geom_cartesian_face_center";
  "geom_cartesian_face_normal";
]
let is_geom_cartesian_builtin name = List.mem name geom_cartesian_builtins

let geom_cartesian_fvm_builtins = [
  "fvm_equation_init";
]
let is_geom_cartesian_fvm_builtin name = List.mem name geom_cartesian_fvm_builtins

(* Track declared struct definitions so field-name lookups during codegen
   can resolve to the right fields and types. *)
let user_structs : (string, struct_field list) Hashtbl.t = Hashtbl.create 16

(* Names of struct types that serve as the base of a TGeneric instantiation
   (currently only CartesianMesh, for CartesianMesh[FieldSet]). These are
   emitted as Fortran type extensions, so support-routine dummy arguments of
   this type must stay polymorphic class(...) to accept the monomorphized
   subtype. Every other struct is non-extended (FortScript has no inheritance)
   and lowers to a plain type(...) dummy, which GCC can analyze inside
   do concurrent loops. *)
let generic_base_names : (string, unit) Hashtbl.t = Hashtbl.create 8
let is_generic_base name = Hashtbl.mem generic_base_names name

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

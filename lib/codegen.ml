open Ast
open Fortran_helpers
open Fortran_helpers_plot
open Fortran_helpers_linalg
open Codegen_state
open Codegen_analysis
open Codegen_types
open Codegen_proc
open Codegen_program

(* Entry point for the code generator.

   The implementation is split across sibling Codegen_* modules; this file
   composes them and exposes the entry points expected by callers
   (generate_output, generate, gpu_kernel_artifact). *)

(* Re-export the GPU kernel artifact type so callers can still reference
   Codegen.gpu_kernel_artifact (see bin/main.ml). *)
type gpu_kernel_artifact = Codegen_state.gpu_kernel_artifact = {
  name: string;
  filename: string;
  params: param list;
  body: stmt list;
  source: string;
}

type generated_output = Codegen_state.generated_output = {
  main_source: string;
  gpu_kernels: gpu_kernel_artifact list;
}

let gen_function fd =
  gen_procedure fd

let generate_output (program : program) : generated_output =
  let buf = Buffer.create 4096 in
  let reachable = reachable_function_names program in
  let analysis_program =
    List.filter (function
      | FuncDef fd -> function_is_reachable reachable fd
      | _ -> true
    ) program
  in
  let uses_plotting = program_uses_plotting analysis_program in
  let uses_h5 = program_uses_h5 analysis_program in
  let uses_xdmf = program_uses_xdmf analysis_program in
  let uses_lapack_qr = program_uses_lapack_qr analysis_program in
  let uses_lapack_solve = program_uses_lapack_solve analysis_program in
  let uses_lapack_svd = program_uses_lapack_svd analysis_program in
  let uses_lapack_eig = program_uses_lapack_eig analysis_program in
  let uses_random_fill = program_uses_random_fill analysis_program in
  let uses_uniform_fill = program_uses_uniform_fill analysis_program in
  let uses_random_seed = program_uses_random_seed analysis_program in
  let uses_prand_uniform = program_uses_prand_uniform analysis_program in
  let uses_prand_uniform_thread = program_uses_prand_uniform_thread analysis_program in
  let uses_prand_seed_parallel = program_uses_prand_seed_parallel analysis_program in
  (* Any support.random RNG pulls in the hand-written prand_mod backing module. *)
  let uses_prand =
    uses_random_fill || uses_uniform_fill || uses_random_seed ||
    uses_prand_uniform || uses_prand_uniform_thread || uses_prand_seed_parallel in
  let uses_geom_stl_ascii = program_uses_geom_stl_ascii analysis_program in
  let uses_geom_stl_binary = program_uses_geom_stl_binary analysis_program in
  let uses_coarrays = program_uses_coarrays analysis_program in
  let callable_types = collect_callable_types analysis_program in

  (* Register user-defined functions *)
  Hashtbl.clear user_functions;
  Hashtbl.clear user_structs;
  Hashtbl.clear callable_interfaces;
  List.iter (function
    | StructDef (name, fields) -> Hashtbl.replace user_structs name fields
    | _ -> ()
  ) program;
  Hashtbl.clear global_coarray_vars;
  Hashtbl.clear global_var_types;
  Hashtbl.clear generic_base_names;
  gpu_kernels := [];
  gpu_kernel_counter := 0;
  parallel_feature_counter := 0;
  current_proc_name := None;
  lapack_qr_enabled := uses_lapack_qr;
  lapack_solve_enabled := uses_lapack_solve;
  lapack_svd_enabled := uses_lapack_svd;
  lapack_eig_enabled := uses_lapack_eig;
  random_fill_enabled := uses_random_fill;
  uniform_fill_enabled := uses_uniform_fill;
  random_seed_enabled := uses_random_seed;
  prand_uniform_enabled := uses_prand_uniform;
  prand_uniform_thread_enabled := uses_prand_uniform_thread;
  prand_seed_parallel_enabled := uses_prand_seed_parallel;
  geom_stl_ascii_enabled := uses_geom_stl_ascii;
  geom_stl_binary_enabled := uses_geom_stl_binary;
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
  compute_pure_functions analysis_program;

  Buffer.add_string buf "module fortscript_mod\n";
  (* Pull in h5fortran's high-level h5write/h5read at module scope so all
     contained subroutines see them via host association. *)
  if uses_h5 then
    Buffer.add_string buf "  use h5fortran, only: h5write, h5read\n";
  if uses_geom_stl_ascii || uses_geom_stl_binary then
    Buffer.add_string buf "  use geom_stl_read_mod\n";
  (* Pull in the hand-written prand_mod backing module for support.random. The
     RNG helper subroutines live there now instead of being injected inline. *)
  if uses_prand then
    Buffer.add_string buf "  use prand_mod\n";
  Buffer.add_string buf "  implicit none\n\n";

  (* Struct type definitions *)
  let structs = List.filter_map (fun d ->
    match d with StructDef (name, fields) -> Some (name, fields) | _ -> None
  ) program in
  List.iter (fun (name, fields) ->
    Buffer.add_string buf (gen_struct name fields);
    Buffer.add_string buf "\n"
  ) structs;

  (* Generic instantiations (e.g., CartesianMesh[TemperatureFlow]) are emitted
     after the base struct definitions; they extend the base struct with one
     allocatable per type-parameter struct field. *)
  let generic_instances = collect_generic_instantiations analysis_program in
  (* Record the base names so struct dummies of a generic base stay class(...). *)
  List.iter (fun (base, _) -> Hashtbl.replace generic_base_names base ()) generic_instances;
  List.iter (fun (base, args) ->
    Buffer.add_string buf (gen_generic_instantiation base args structs);
    Buffer.add_string buf "\n"
  ) generic_instances;

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
    match d with
    | FuncDef fd when function_is_reachable reachable fd -> Some fd
    | _ -> None
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
  if funcs <> [] || uses_plotting || uses_lapack_qr || uses_lapack_solve || uses_lapack_svd || uses_lapack_eig ||
     uses_random_fill || uses_uniform_fill || uses_random_seed then begin
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
  if uses_xdmf then begin
    Buffer.add_string buf (gen_xdmf_helpers ());
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
    (* support.random RNG helpers are no longer injected here; they are provided
       by the hand-written prand_mod module pulled in with `use prand_mod`. *)
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
    (* Assign module-level global initializers before main(). The module
       block emits only the declaration; without this loop, scalar globals
       like `BDIM_PI: float = 3.14...` would be left uninitialized in
       Fortran (silently 0 or garbage). *)
    List.iter (fun (name, _typ, init) ->
      match init with
      | Some e -> Buffer.add_string buf (Printf.sprintf "  %s = %s\n" name (Codegen_expr.gen_expr e))
      | None -> ()
    ) globals;
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

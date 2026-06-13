open Ast
open Codegen_state
open Codegen_analysis
open Codegen_types
open Codegen_expr
open Codegen_expr_geom_cartesian

(* Statement codegen: parameter-modification analysis, GPU-kernel parameter
   marshaling, and the main gen_stmt mutual-recursion block. *)

(* ---- Detect if a subroutine modifies a parameter ---- *)
let rec param_is_modified param_name stmts =
  param_is_modified_seen (Hashtbl.create 16) param_name stmts

and param_is_modified_seen seen param_name stmts =
  List.exists (stmt_modifies seen param_name) stmts

and stmt_modifies seen pname = function
  | Assign (target, _) -> lvalue_references pname target
  | AugAssign (_, target, _) -> lvalue_references pname target
  | ExprStmt (Call (callee, args)) -> call_modifies_actual seen pname callee args
  | If { body; elifs; else_body; _ } ->
    param_is_modified_seen seen pname body ||
    List.exists (fun (_, b) -> param_is_modified_seen seen pname b) elifs ||
    param_is_modified_seen seen pname else_body
  | For { for_body; _ } -> param_is_modified_seen seen pname for_body
  | While (_, body) -> param_is_modified_seen seen pname body
  | SyncAll | Allocate _ -> false
  | _ -> false

and call_modifies_actual seen pname callee args =
  match Hashtbl.find_opt user_functions callee with
  | None -> false
  | Some fd ->
    let actuals = expand_call_args callee args in
    let rec any_modified formals actuals =
      match formals, actuals with
      | formal :: rest_formals, actual :: rest_actuals ->
        let key = callee ^ ":" ^ formal.param_name in
        let this_modified =
          lvalue_references pname actual &&
          not (Hashtbl.mem seen key) &&
          (Hashtbl.add seen key true;
           param_is_modified_seen seen formal.param_name fd.body)
        in
        this_modified || any_modified rest_formals rest_actuals
      | _ -> false
    in
    any_modified fd.params actuals

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

(* Build the iteration-private name sets for a parallel loop. Explicit
   @local/@local_init/@reduce names are honored, inner sequential loop variables
   are made local, and every other scalar that is assigned in the body is
   auto-collected so the loop carries no shared scalar state. Whole-variable
   scalars written before being read become plain locals; the rest carry their
   pre-loop value in via local_init. Returns (local_names, local_init_names),
   which map to do concurrent local()/local_init() and to OpenMP
   private()/firstprivate(). *)
let compute_locality var for_body local_vars local_init_vars reduce_var_names =
  let is_scalar name =
    match Hashtbl.find_opt current_var_types name with
    | Some (TInt | TFloat | TBool | TString) -> true
    | _ -> false
  in
  let explicit = var :: local_vars @ local_init_vars @ reduce_var_names in
  let inner_loop_vars =
    collect_inner_loop_vars for_body
    |> List.sort_uniq String.compare
    |> List.filter (fun v -> not (List.mem v explicit))
  in
  let reserved = explicit @ inner_loop_vars in
  let auto_candidates =
    collect_assigned_var_names for_body
    |> List.sort_uniq String.compare
    |> List.filter (fun v -> (not (List.mem v reserved)) && is_scalar v)
  in
  let auto_local, auto_local_init =
    List.partition (fun v -> assigned_clean_first v for_body) auto_candidates
  in
  let local_names = local_vars @ reduce_var_names @ inner_loop_vars @ auto_local in
  let local_init_names = local_init_vars @ auto_local_init in
  (local_names, local_init_names)

(* ---- Statement codegen ---- *)
let rec gen_stmt indent stmt =
  (* Save outer pre-statement context so nested gen_stmt calls don't interfere. *)
  let saved_prestmts = !fstr_prestmts in
  fstr_prestmts := [];
  let result = gen_stmt_core indent stmt in
  let pre = List.rev !fstr_prestmts in
  fstr_prestmts := saved_prestmts;
  match pre with
  | [] -> result
  | _ ->
    let ind = indent_str indent in
    let pre_str = String.concat "\n" (List.map (fun s -> ind ^ s) pre) in
    if result = "" then pre_str else pre_str ^ "\n" ^ result

and gen_stmt_core indent stmt =
  let ind = indent_str indent in
  match stmt with
  | Assign (target, value) ->
    Printf.sprintf "%s%s = %s" ind (gen_lvalue target) (gen_expr value)

  | VarDecl (name, _, Some init) ->
    (* Emit initialization at point of declaration *)
    Printf.sprintf "%s%s = %s" ind name (gen_expr init)

  | VarDecl (_, _, None) ->
    ""  (* declaration only - hoisted to top *)

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

  | Break ->
    Printf.sprintf "%sexit" ind

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

  | For { var; start_expr; end_expr; step_expr; for_body; parallel; gpu; omp;
          local_vars; local_init_vars; reduce_specs } ->
    let buf = Buffer.create 256 in
    (* Keep loop variable 0-based (matching FortScript semantics) so that
       array indexing with +1 offset is always correct. range(n) -> 0..n-1 *)
    let start_f = gen_expr start_expr in
    let end_f = gen_expr end_expr ^ " - 1" in
    if gpu then
      gen_gpu_kernel_call indent {
        var;
        start_expr;
        end_expr;
        step_expr;
        for_body;
        parallel;
        gpu;
        omp;
        local_vars;
        local_init_vars;
        reduce_specs;
      }
    else if omp then begin
      (* @omp: lower to an OpenMP parallel do. The directive parallelizes the
         loop directly with no dependence analysis, so neighbor-gather stencils
         that GCC's do concurrent autopar cannot thread still run multithreaded
         under gfortran -fopenmp. Scalars assigned in the body become private
         (or firstprivate when read before written) so iterations share no
         scalar state, and explicit @reduce maps to the native OpenMP reduction
         clause. The loop index is private by default under worksharing. *)
      let reduce_var_names =
        List.concat_map (fun spec -> spec.reduce_vars) reduce_specs in
      let private_names, firstprivate_names =
        compute_locality var for_body local_vars local_init_vars reduce_var_names in
      let clause kw names = match names with
        | [] -> ""
        | _ -> Printf.sprintf " %s(%s)" kw (String.concat ", " names)
      in
      let reduction_clause =
        String.concat "" (List.map (fun spec ->
          Printf.sprintf " reduction(%s:%s)"
            (omp_reduction_op spec.reduce_op)
            (String.concat ", " spec.reduce_vars)) reduce_specs)
      in
      Buffer.add_string buf (Printf.sprintf "%s!$omp parallel do default(shared)%s%s%s\n"
        ind (clause "private" private_names) (clause "firstprivate" firstprivate_names)
        reduction_clause);
      (match step_expr with
       | None ->
         Buffer.add_string buf (Printf.sprintf "%sdo %s = %s, %s\n" ind var start_f end_f)
       | Some step ->
         Buffer.add_string buf (Printf.sprintf "%sdo %s = %s, %s, %s\n" ind var start_f end_f (gen_expr step)));
      gen_stmts_into buf (indent + 1) for_body;
      Buffer.add_string buf (Printf.sprintf "%send do\n" ind);
      Buffer.add_string buf (Printf.sprintf "%s!$omp end parallel do" ind);
      Buffer.contents buf
    end
    else begin
      if parallel then begin
        (* Emit native Fortran 2018 do concurrent with LOCAL / LOCAL_INIT
           clauses. Every scalar assigned in the body is made iteration-local so
           GCC's autopar does not see shared scalar state as a loop-carried
           dependence. Reductions still use a per-iteration array summed
           sequentially afterwards because gfortran does not yet parallelize
           do concurrent REDUCE. *)
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
        let local_names, local_init_names =
          compute_locality var for_body local_vars local_init_vars reduce_var_names in
        let local_clause = match local_names with
          | [] -> ""
          | names -> " local(" ^ String.concat ", " names ^ ")"
        in
        let local_init_clause = match local_init_names with
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
    else if !random_fill_enabled && name = "random_fill" then
      gen_random_fill_stmt indent lowered_args
    else if !uniform_fill_enabled && name = "uniform_fill" then
      gen_uniform_fill_stmt indent lowered_args
    else if !random_seed_enabled && name = "seed" then
      gen_random_seed_stmt indent lowered_args
    else if !prand_seed_parallel_enabled && name = "prand_seed_parallel" then
      gen_prand_seed_parallel_stmt indent lowered_args
    else if name = "append" then
      gen_append_stmt indent lowered_args
    else if !geom_stl_ascii_enabled && name = "geom_stl_read_ascii" then
      gen_geom_stl_read_ascii_stmt indent lowered_args
    else if !geom_stl_binary_enabled && name = "geom_stl_read_binary" then
      gen_geom_stl_read_binary_stmt indent lowered_args
    else if name = "geom_cartesian_uniform" then
      gen_geom_cartesian_uniform_stmt indent lowered_args
    else if name = "geom_cartesian_refine_cell" then
      gen_geom_cartesian_refine_cell_stmt indent lowered_args
    else if name = "geom_cartesian_refine_to_sdf" then
      gen_geom_cartesian_refine_to_sdf_stmt indent lowered_args
    else if name = "geom_cartesian_refine_band" then
      gen_geom_cartesian_refine_band_stmt indent lowered_args
    else if name = "geom_cartesian_coarsen_cell" then
      gen_geom_cartesian_coarsen_cell_stmt indent lowered_args
    else if name = "geom_cartesian_face_center" then
      gen_geom_cartesian_face_center_stmt indent lowered_args
    else if name = "geom_cartesian_face_normal" then
      gen_geom_cartesian_face_normal_stmt indent lowered_args
    else if name = "fvm_equation_init" then
      gen_fvm_equation_init_stmt indent lowered_args
    else if is_coarray_collective name then
      gen_coarray_collective_stmt indent name lowered_args
    else if is_h5_builtin name then
      gen_h5_stmt indent name lowered_args
    else if is_xdmf_builtin name then
      gen_xdmf_stmt indent name lowered_args
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

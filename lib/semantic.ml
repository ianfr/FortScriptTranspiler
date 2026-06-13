(* Entry point for the semantic checker.

   The implementation is split across several sibling modules; this file
   composes them in the order expected by callers and re-exports the
   SemanticError exception so external code (e.g. bin/main.ml) keeps working
   with Semantic.check and Semantic.SemanticError. *)

(* Re-export the exception so callers can still catch Semantic.SemanticError. *)
exception SemanticError = Semantic_types.SemanticError

(* Re-export the error record for any external consumer that references it. *)
type error = Semantic_types.error = { msg: string }

let check program =
  let errors = ref [] in
  (* Check recursion *)
  let call_graph = Semantic_calls.build_call_graph program in
  errors := !errors @ Semantic_calls.detect_recursion call_graph;
  (* Check duplicate exported names after import expansion *)
  errors := !errors @ Semantic_decls.validate_top_level_names program;
  (* Check struct types *)
  errors := !errors @ Semantic_decls.validate_structs program;
  (* Check callable-parameter restrictions and default-value rules. *)
  errors := !errors @ Semantic_decls.validate_callable_support program;
  (* Check coarray-specific restrictions *)
  errors := !errors @ Semantic_parallel.validate_coarrays program;
  (* Check do concurrent clause syntax and typing. *)
  errors := !errors @ Semantic_parallel.validate_do_concurrent_features program;
  (* Check @gpu loop-specific restrictions. *)
  errors := !errors @ Semantic_parallel.validate_gpu_loops program;
  (* Check loop-exit control flow. *)
  errors := !errors @ Semantic_parallel.validate_break_usage program;
  (* Check slice-specific constraints *)
  errors := !errors @ Semantic_builtins.validate_slices program;
  (* Check append builtin usage. *)
  errors := !errors @ Semantic_builtins.validate_append_calls program;
  (* Check builtin plotting usage *)
  errors := !errors @ Semantic_builtins.validate_plotting program;
  (* Check HDF5 builtin usage *)
  errors := !errors @ Semantic_builtins.validate_h5_calls program;
  (* Check XDMF builtin usage *)
  errors := !errors @ Semantic_builtins.validate_xdmf_calls program;
  (* Check standard-library stubs with custom lowering. *)
  errors := !errors @ Semantic_builtins.validate_stdlib_calls program;
  (* Check user-defined call arity and callable arguments. *)
  errors := !errors @ Semantic_decls.validate_function_calls program;
  (* Race-condition checks for @omp loops. These are hard errors: a flagged loop
     is either an undeclared reduction or a loop-carried dependence, both of
     which are unsafe under OpenMP. Annotate with @reduce/@local_init to pass. *)
  errors := !errors @ Semantic_parallel.validate_omp_loop_safety program;
  if !errors <> [] then
    raise (SemanticError (String.concat "\n" (List.map (fun e -> "Error: " ^ e) !errors)))

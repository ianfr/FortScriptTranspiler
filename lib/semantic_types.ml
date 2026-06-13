open Ast

(* Shared types, sets/maps, type predicates, and stdlib stub detectors. *)

type error = {
  msg: string;
  (* Could add location info later *)
}

exception SemanticError of string

module StringSet = Set.Make(String)
module StringMap = Map.Make(String)

(* Try to evaluate an expression as a compile-time int. *)
let try_const_int = function
  | IntLit n -> Some n
  | UnaryOp (Neg, IntLit n) -> Some (-n)
  | _ -> None

(* Predicate for deferred ':' array dimensions. *)
let is_deferred_dim = function
  | DeferredDim -> true
  | FixedDim _ -> false

(* Direct coarray-type test. *)
let is_coarray_type = function
  | TCoarray _ -> true
  | _ -> false

(* Walk a type and report any nested coarray component. *)
let rec type_contains_coarray = function
  | TCoarray _ -> true
  | TArray (elem_t, _) -> type_contains_coarray elem_t
  | TFunc (param_types, return_type) ->
    List.exists type_contains_coarray param_types || type_contains_coarray return_type
  | _ -> false

(* Walk a type and report any nested callable component. *)
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

let is_int_type = function
  | TInt -> true
  | _ -> false

let is_float_type = function
  | TFloat -> true
  | _ -> false

(* Detect the support.linalg.qr stub: 3 deferred 2-D float arrays. *)
let is_lapack_qr_stub = function
  | { func_name = "qr"; params; return_type = TVoid; body = [Pass] } ->
    List.length params = 3 &&
    List.for_all (fun p -> is_two_dim_float_array p.param_type) params
  | _ -> false

(* Detect the support.linalg.svd stub: 4 args (a, u, s, vt) with the right shapes. *)
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

(* Detect the support.linalg.eig stub: 4 args (a, wr, wi, vr) with the right shapes. *)
let is_lapack_eig_stub = function
  | { func_name = "eig"; params; return_type = TVoid; body = [Pass] } ->
    List.length params = 4 &&
    (match params with
     | [a_param; wr_param; wi_param; vr_param] ->
       is_two_dim_float_array a_param.param_type &&
       is_one_dim_float_array wr_param.param_type &&
       is_one_dim_float_array wi_param.param_type &&
       is_two_dim_float_array vr_param.param_type
     | _ -> false)
  | _ -> false

(* Detect the support.linalg.solve stub: 3 args (a, b, x). *)
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

(* Detect the support.random.random_fill stub: a single 1-D float array. *)
let is_random_fill_stub = function
  | { func_name = "random_fill"; params; return_type = TVoid; body = [Pass] } ->
    List.length params = 1 &&
    (match params with
     | [x_param] -> is_one_dim_float_array x_param.param_type
     | _ -> false)
  | _ -> false

(* Detect the support.random.uniform_fill stub: (low, high, x). *)
let is_uniform_fill_stub = function
  | { func_name = "uniform_fill"; params; return_type = TVoid; body = [Pass] } ->
    List.length params = 3 &&
    (match params with
     | [low_param; high_param; x_param] ->
       is_float_type low_param.param_type &&
       is_float_type high_param.param_type &&
       is_one_dim_float_array x_param.param_type
     | _ -> false)
  | _ -> false

(* Detect the support.random.seed stub: a single int. *)
let is_random_seed_stub = function
  | { func_name = "seed"; params; return_type = TVoid; body = [Pass] } ->
    List.length params = 1 &&
    (match params with
     | [s_param] -> is_int_type s_param.param_type
     | _ -> false)
  | _ -> false

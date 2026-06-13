open Ast
open Semantic_types

(* Call graph construction and recursion detection. *)

(* Collect all function calls within a list of statements *)
let rec calls_in_stmts stmts =
  List.fold_left (fun acc s -> StringSet.union acc (calls_in_stmt s)) StringSet.empty stmts

and calls_in_stmt = function
  | Assign (_, e) -> calls_in_expr e
  | VarDecl (_, _, Some e) -> calls_in_expr e
  | VarDecl (_, _, None) -> StringSet.empty
  | AugAssign (_, _, e) -> calls_in_expr e
  | Return (Some e) -> calls_in_expr e
  | Return None -> StringSet.empty
  | Break -> StringSet.empty
  | If { cond; body; elifs; else_body } ->
    let s = calls_in_expr cond in
    let s = StringSet.union s (calls_in_stmts body) in
    let s = List.fold_left (fun acc (c, b) ->
      StringSet.union acc (StringSet.union (calls_in_expr c) (calls_in_stmts b))
    ) s elifs in
    StringSet.union s (calls_in_stmts else_body)
  | For { start_expr; end_expr; step_expr; for_body; _ } ->
    let s = calls_in_expr start_expr in
    let s = StringSet.union s (calls_in_expr end_expr) in
    let s = (match step_expr with Some e -> StringSet.union s (calls_in_expr e) | None -> s) in
    StringSet.union s (calls_in_stmts for_body)
  | While (cond, body) ->
    StringSet.union (calls_in_expr cond) (calls_in_stmts body)
  | ExprStmt e -> calls_in_expr e
  | Print args -> List.fold_left (fun acc e -> StringSet.union acc (calls_in_expr e)) StringSet.empty args
  | SyncAll -> StringSet.empty
  | Allocate (_, dims) ->
    List.fold_left (fun acc e -> StringSet.union acc (calls_in_expr e)) StringSet.empty dims
  | Pass -> StringSet.empty

and calls_in_expr = function
  | FString parts ->
    List.fold_left (fun acc part -> match part with
      | FStrExpr (e, _) -> StringSet.union acc (calls_in_expr e)
      | FStrLit _ -> acc) StringSet.empty parts
  | IntLit _ | FloatLit _ | BoolLit _ | StringLit _ | Var _ -> StringSet.empty
  | BinOp (_, l, r) -> StringSet.union (calls_in_expr l) (calls_in_expr r)
  | UnaryOp (_, e) -> calls_in_expr e
  | Call (name, args) ->
    let s = StringSet.singleton name in
    List.fold_left (fun acc e -> StringSet.union acc (calls_in_expr e)) s args
  | Index (e, subs) ->
    List.fold_left (fun acc sub -> StringSet.union acc (calls_in_subscript sub))
      (calls_in_expr e) subs
  | CoarrayIndex (e, idxs) ->
    List.fold_left (fun acc i -> StringSet.union acc (calls_in_expr i))
      (calls_in_expr e) idxs
  | FieldAccess (e, _) -> calls_in_expr e
  | ArrayLit elems ->
    List.fold_left (fun acc e -> StringSet.union acc (calls_in_expr e)) StringSet.empty elems
  | RangeExpr (a, b, c) ->
    let s = StringSet.union (calls_in_expr a) (calls_in_expr b) in
    (match c with Some e -> StringSet.union s (calls_in_expr e) | None -> s)

and calls_in_subscript = function
  | IndexSubscript e -> calls_in_expr e
  | SliceSubscript (start_e, stop_e, step_e) ->
    (* Slice bounds can contain arbitrary expressions and calls. *)
    let s = match start_e with Some e -> calls_in_expr e | None -> StringSet.empty in
    let s = match stop_e with Some e -> StringSet.union s (calls_in_expr e) | None -> s in
    (match step_e with Some e -> StringSet.union s (calls_in_expr e) | None -> s)

(* Build a name -> set-of-callees map for every user-defined function. *)
let build_call_graph (program : program) : StringSet.t StringMap.t =
  List.fold_left (fun graph decl ->
    match decl with
    | FuncDef { func_name; body; _ } ->
      StringMap.add func_name (calls_in_stmts body) graph
    | _ -> graph
  ) StringMap.empty program

(* DFS cycle detection *)
let detect_recursion call_graph =
  let errors = ref [] in
  let visited = Hashtbl.create 16 in
  let in_stack = Hashtbl.create 16 in
  let rec dfs node path =
    if Hashtbl.mem in_stack node then begin
      let cycle = node :: (List.rev path) in
      let cycle_str = String.concat " -> " cycle in
      errors := (Printf.sprintf "Recursion detected: %s" cycle_str) :: !errors
    end else if not (Hashtbl.mem visited node) then begin
      Hashtbl.add visited node true;
      Hashtbl.add in_stack node true;
      (match StringMap.find_opt node call_graph with
       | Some callees ->
         StringSet.iter (fun callee ->
           if StringMap.mem callee call_graph then  (* only check user-defined functions *)
             dfs callee (node :: path)
         ) callees
       | None -> ());
      Hashtbl.remove in_stack node
    end
  in
  StringMap.iter (fun name _ -> dfs name []) call_graph;
  !errors

type loc = {
  line: int;
  col: int;
}

type array_dim =
  | FixedDim of expr
  | DeferredDim

and typ =
  | TInt
  | TFloat
  | TBool
  | TString
  | TFunc of typ list * typ          (* parameter types, return type *)
  | TArray of typ * array_dim list   (* element type, dimension specs *)
  | TCoarray of typ * expr option list  (* extra codim specs before final *; None=deferred, Some e=fixed *)
  | TStruct of string
  | TVoid

and binop =
  | Add | Sub | Mul | Div | Mod | Pow
  | Eq | Neq | Lt | Gt | Le | Ge
  | And | Or
  | DotProd  (* internal: rewritten from dot() calls *)

and unop =
  | Neg | Not

and subscript =
  | IndexSubscript of expr  (* Single element access *)
  | SliceSubscript of expr option * expr option * expr option  (* start:stop:step *)

and expr =
  | IntLit of int
  | FloatLit of float
  | BoolLit of bool
  | StringLit of string
  | Var of string
  | BinOp of binop * expr * expr
  | UnaryOp of unop * expr
  | Call of string * expr list
  | Index of expr * subscript list
  | CoarrayIndex of expr * expr list  (* image indices, 0-based *)
  | FieldAccess of expr * string
  | ArrayLit of expr list
  | RangeExpr of expr * expr * expr option  (* start, stop, step *)

type stmt =
  | Assign of expr * expr
  | VarDecl of string * typ * expr option
  | AugAssign of binop * expr * expr        (* target += value etc. *)
  | Return of expr option
  | If of if_block
  | For of for_block
  | While of expr * stmt list
  | ExprStmt of expr
  | Print of expr list
  | SyncAll
  | Allocate of string * expr list
  | Pass

and reduction_op =
  | ReduceAdd
  | ReduceMul
  | ReduceMax
  | ReduceMin
  | ReduceIand
  | ReduceIor
  | ReduceIeor
  | ReduceAnd
  | ReduceOr
  | ReduceEqv
  | ReduceNeqv

and reduction_spec = {
  reduce_op: reduction_op;
  reduce_vars: string list;
}

and if_block = {
  cond: expr;
  body: stmt list;
  elifs: (expr * stmt list) list;
  else_body: stmt list;
}

and for_block = {
  var: string;
  start_expr: expr;
  end_expr: expr;
  step_expr: expr option;
  for_body: stmt list;
  parallel: bool;
  gpu: bool;
  local_vars: string list;
  local_init_vars: string list;
  reduce_specs: reduction_spec list;
}

type struct_field = {
  field_name: string;
  field_type: typ;
}

type param = {
  param_name: string;
  param_type: typ;
  default_value: expr option;
}

type decl =
  | Import of string
  | StructDef of string * struct_field list
  | FuncDef of func_def
  | GlobalVarDecl of string * typ * expr option

and func_def = {
  func_name: string;
  params: param list;
  return_type: typ;
  body: stmt list;
}

type program = decl list

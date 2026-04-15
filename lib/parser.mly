%{
open Ast

type loop_annotations = {
  has_par: bool;
  has_gpu: bool;
  locals: string list;
  local_inits: string list;
  reductions: reduction_spec list;
}

let empty_loop_annotations = {
  has_par = false;
  has_gpu = false;
  locals = [];
  local_inits = [];
  reductions = [];
}

let merge_loop_annotations left right = {
  has_par = left.has_par || right.has_par;
  has_gpu = left.has_gpu || right.has_gpu;
  locals = left.locals @ right.locals;
  local_inits = left.local_inits @ right.local_inits;
  reductions = left.reductions @ right.reductions;
}

let reduction_op_of_name = function
  | "add" | "sum" -> ReduceAdd
  | "mul" | "product" -> ReduceMul
  | "max" -> ReduceMax
  | "min" -> ReduceMin
  | "iand" -> ReduceIand
  | "ior" -> ReduceIor
  | "ieor" | "xor" -> ReduceIeor
  | "and" -> ReduceAnd
  | "or" -> ReduceOr
  | "eqv" -> ReduceEqv
  | "neqv" -> ReduceNeqv
  | name -> failwith ("Unknown reduction operator: " ^ name)

let build_for_stmt annots v args body =
  let (s, e, step) = match args with
    | [e] -> (IntLit 0, e, None)
    | [s; e] -> (s, e, None)
    | [s; e; st] -> (s, e, Some st)
    | _ -> failwith "range() takes 1-3 arguments"
  in
  For {
    var = v;
    start_expr = s;
    end_expr = e;
    step_expr = step;
    for_body = body;
    parallel = annots.has_par;
    gpu = annots.has_gpu;
    local_vars = annots.locals;
    local_init_vars = annots.local_inits;
    reduce_specs = annots.reductions;
  }
%}

%token <int> INT_LIT
%token <float> FLOAT_LIT
%token <string> STRING_LIT
%token <string> IDENT

%token DEF RETURN IF ELIF ELSE FOR IN WHILE STRUCT IMPORT
%token AND OR NOT TRUE FALSE PASS PRINT RANGE
%token SYNC ALLOCATE
%token TINT TFLOAT TBOOL TSTRING ARRAY TVOID CALLABLE
%token AT_PAR AT_GPU AT_LOCAL AT_LOCAL_INIT AT_REDUCE

%token ARROW DOUBLESTAR DOTDOT
%token PLUSEQ MINUSEQ STAREQ SLASHEQ
%token EQEQ NEQ LE GE LT GT
%token PLUS MINUS STAR SLASH PERCENT
%token EQ

%token LPAREN RPAREN LBRACKET RBRACKET LBRACE RBRACE
%token COLON COMMA DOT

%token INDENT DEDENT NEWLINE EOF

%start <Ast.program> program

%%

program:
  | skip_newlines ds=list(decl) EOF { ds }
;

skip_newlines:
  | (* empty *) {}
  | NEWLINE skip_newlines {}
;

decl:
  | i=import_decl skip_newlines { i }
  | s=struct_def skip_newlines { s }
  | f=func_def skip_newlines   { f }
  | g=global_var skip_newlines { g }
;

import_decl:
  | IMPORT path=import_path NEWLINE
    { Import path }
;

import_path:
  | path=module_path
    { path }
  | path=relative_import_path
    { path }
;

relative_prefix:
  | step=relative_step
    { step }
  | step=relative_step rest=relative_prefix
    { step ^ rest }
;

relative_step:
  | DOT SLASH
    { "./" }
  | DOTDOT SLASH
    { "../" }
;

module_path:
  | parts=separated_nonempty_list(DOT, IDENT)
    { String.concat "/" parts }
;

relative_import_path:
  | prefix=relative_prefix head=IDENT tail=list(relative_import_segment)
    { prefix ^ head ^ String.concat "" tail }
;

relative_import_segment:
  | DOT name=IDENT
    { "/" ^ name }
  | SLASH name=IDENT
    { "/" ^ name }
;

(* ---- Struct ---- *)
struct_def:
  | STRUCT name=IDENT COLON NEWLINE INDENT fields=nonempty_list(struct_field) DEDENT
    { StructDef (name, fields) }
;

struct_field:
  | name=IDENT COLON t=typ NEWLINE { { field_name = name; field_type = t } }
;

(* ---- Functions ---- *)
func_def:
  | DEF name=IDENT LPAREN params=separated_list(COMMA, param) RPAREN ret=return_annotation COLON NEWLINE INDENT body=stmt_list DEDENT
    { FuncDef { func_name = name; params; return_type = ret; body } }
;

param:
  | name=IDENT COLON t=typ default_value=param_default
    { { param_name = name; param_type = t; default_value } }
;

param_default:
  | (* empty *) { None }
  | EQ e=expr   { Some e }
;

return_annotation:
  | (* empty *)   { TVoid }
  | ARROW t=typ   { t }
;

(* ---- Global variables ---- *)
global_var:
  | name=IDENT COLON t=typ EQ e=expr NEWLINE
    { GlobalVarDecl (name, t, Some e) }
  | name=IDENT COLON t=typ NEWLINE
    { GlobalVarDecl (name, t, None) }
;

(* ---- Types ---- *)
typ:
  | TINT    { TInt }
  | TINT STAR { TCoarray (TInt, []) }
  | TINT STAR LBRACKET cs=separated_nonempty_list(COMMA, codim_spec) RBRACKET
    { TCoarray (TInt, cs) }
  | TFLOAT  { TFloat }
  | TFLOAT STAR { TCoarray (TFloat, []) }
  | TFLOAT STAR LBRACKET cs=separated_nonempty_list(COMMA, codim_spec) RBRACKET
    { TCoarray (TFloat, cs) }
  | TBOOL   { TBool }
  | TBOOL STAR { TCoarray (TBool, []) }
  | TBOOL STAR LBRACKET cs=separated_nonempty_list(COMMA, codim_spec) RBRACKET
    { TCoarray (TBool, cs) }
  | TSTRING { TString }
  | TSTRING STAR { TCoarray (TString, []) }
  | TSTRING STAR LBRACKET cs=separated_nonempty_list(COMMA, codim_spec) RBRACKET
    { TCoarray (TString, cs) }
  | TVOID   { TVoid }
  | CALLABLE LBRACKET sig_t=callable_signature RBRACKET
    { let (param_types, return_type) = sig_t in TFunc (param_types, return_type) }
  | ARRAY LBRACKET t=typ dims=array_dims RBRACKET
    { TArray (t, dims) }
  | ARRAY STAR LBRACKET t=typ dims=array_dims RBRACKET
    { TCoarray (TArray (t, dims), []) }
  | ARRAY STAR LBRACKET t=typ dims=array_dims RBRACKET LBRACKET cs=separated_nonempty_list(COMMA, codim_spec) RBRACKET
    { TCoarray (TArray (t, dims), cs) }
  | name=IDENT { TStruct name }
  | name=IDENT STAR { TCoarray (TStruct name, []) }
  | name=IDENT STAR LBRACKET cs=separated_nonempty_list(COMMA, codim_spec) RBRACKET
    { TCoarray (TStruct name, cs) }
;

callable_signature:
  | arg_t=typ COMMA ret_t=typ
    { ([arg_t], ret_t) }
  | arg_t=typ COMMA rest=callable_signature
    { let (arg_types, ret_t) = rest in (arg_t :: arg_types, ret_t) }
;

array_dims:
  | (* empty *) { [DeferredDim] }
  | COMMA dims=separated_nonempty_list(COMMA, array_dim) { dims }
;

array_dim:
  | COLON { DeferredDim }
  | e=expr { FixedDim e }
;

(* A single codimension specification: ':' for deferred, expr for fixed size *)
codim_spec:
  | COLON { None }
  | e=expr { Some e }
;

(* ---- Statements ---- *)
stmt_list:
  | stmts=nonempty_list(stmt) { stmts }
;

stmt:
  | s=simple_stmt NEWLINE { s }
  | s=compound_stmt       { s }
;

(* Reorganized to avoid reduce/reduce conflict between lvalue and expr.
   VarDecl is unambiguous (IDENT COLON), so it goes first.
   Assignment uses postfix_expr for the target (covers a, a[i], a[1:4], a.f, a[i].f[j], etc.).
   ExprStmt is the fallback. *)
simple_stmt:
  | SYNC                              { SyncAll }
  | ALLOCATE LPAREN name=IDENT COMMA dims=separated_nonempty_list(COMMA, expr) RPAREN
                                      { Allocate (name, dims) }
  | name=IDENT COLON t=typ EQ e=expr    { VarDecl (name, t, Some e) }
  | name=IDENT COLON t=typ              { VarDecl (name, t, None) }
  | target=postfix_expr EQ e=expr       { Assign (target, e) }
  | target=postfix_expr PLUSEQ e=expr   { AugAssign (Add, target, e) }
  | target=postfix_expr MINUSEQ e=expr  { AugAssign (Sub, target, e) }
  | target=postfix_expr STAREQ e=expr   { AugAssign (Mul, target, e) }
  | target=postfix_expr SLASHEQ e=expr  { AugAssign (Div, target, e) }
  | RETURN e=option(expr)               { Return e }
  | PRINT LPAREN args=separated_list(COMMA, expr) RPAREN { Print args }
  | PASS                                 { Pass }
  | e=expr                               { ExprStmt e }
;

compound_stmt:
  | s=if_stmt    { s }
  | s=for_stmt   { s }
  | s=while_stmt { s }
;

if_stmt:
  | IF cond=expr COLON NEWLINE INDENT body=stmt_list DEDENT
    elifs=list(elif_clause)
    else_body=option(else_clause)
    { If { cond; body; elifs; else_body = (match else_body with Some s -> s | None -> []) } }
;

elif_clause:
  | ELIF cond=expr COLON NEWLINE INDENT body=stmt_list DEDENT
    { (cond, body) }
;

else_clause:
  | ELSE COLON NEWLINE INDENT body=stmt_list DEDENT { body }
;

for_stmt:
  | annots=loop_annotations
    FOR v=IDENT IN RANGE LPAREN args=separated_nonempty_list(COMMA, expr) RPAREN COLON NEWLINE
    INDENT body=stmt_list DEDENT
    { build_for_stmt annots v args body }
  | FOR v=IDENT IN RANGE LPAREN args=separated_nonempty_list(COMMA, expr) RPAREN COLON NEWLINE
    INDENT body=stmt_list DEDENT
    { build_for_stmt empty_loop_annotations v args body }
;

loop_annotations:
  | a=loop_annotation { a }
  | a=loop_annotation rest=loop_annotations { merge_loop_annotations a rest }
;

loop_annotation:
  | AT_PAR NEWLINE
    { { empty_loop_annotations with has_par = true } }
  | AT_GPU NEWLINE
    { { empty_loop_annotations with has_gpu = true } }
  | AT_LOCAL LPAREN vars=separated_nonempty_list(COMMA, IDENT) RPAREN NEWLINE
    { { empty_loop_annotations with locals = vars } }
  | AT_LOCAL_INIT LPAREN vars=separated_nonempty_list(COMMA, IDENT) RPAREN NEWLINE
    { { empty_loop_annotations with local_inits = vars } }
  | AT_REDUCE LPAREN op=reduction_op COLON vars=separated_nonempty_list(COMMA, IDENT) RPAREN NEWLINE
    { { empty_loop_annotations with reductions = [{ reduce_op = op; reduce_vars = vars }] } }
;

reduction_op:
  | PLUS { ReduceAdd }
  | STAR { ReduceMul }
  | name=IDENT { reduction_op_of_name name }
  | AND { reduction_op_of_name "and" }
  | OR { reduction_op_of_name "or" }
;

while_stmt:
  | WHILE cond=expr COLON NEWLINE INDENT body=stmt_list DEDENT
    { While (cond, body) }
;

(* ---- Expressions ---- *)
(* Precedence handled by grammar structure, not %prec declarations *)
expr:
  | e=or_expr { e }
;

or_expr:
  | l=or_expr OR r=and_expr  { BinOp (Or, l, r) }
  | e=and_expr               { e }
;

and_expr:
  | l=and_expr AND r=not_expr { BinOp (And, l, r) }
  | e=not_expr                { e }
;

not_expr:
  | NOT e=not_expr    { UnaryOp (Not, e) }
  | e=comparison      { e }
;

comparison:
  | l=arith EQEQ r=arith { BinOp (Eq, l, r) }
  | l=arith NEQ r=arith  { BinOp (Neq, l, r) }
  | l=arith LT r=arith   { BinOp (Lt, l, r) }
  | l=arith GT r=arith   { BinOp (Gt, l, r) }
  | l=arith LE r=arith   { BinOp (Le, l, r) }
  | l=arith GE r=arith   { BinOp (Ge, l, r) }
  | e=arith               { e }
;

arith:
  | l=arith PLUS r=term    { BinOp (Add, l, r) }
  | l=arith MINUS r=term   { BinOp (Sub, l, r) }
  | e=term                  { e }
;

term:
  | l=term STAR r=power    { BinOp (Mul, l, r) }
  | l=term SLASH r=power   { BinOp (Div, l, r) }
  | l=term PERCENT r=power { BinOp (Mod, l, r) }
  | e=power                 { e }
;

power:
  | b=unary DOUBLESTAR e=power { BinOp (Pow, b, e) }
  | e=unary                     { e }
;

unary:
  | MINUS e=unary { UnaryOp (Neg, e) }
  | e=postfix_expr { e }
;

postfix_expr:
  | e=postfix_expr LBRACKET idx=subscript_list RBRACKET
    { Index (e, idx) }
  | e=postfix_expr LBRACE idxs=separated_nonempty_list(COMMA, expr) RBRACE
    { CoarrayIndex (e, idxs) }
  | e=postfix_expr DOT field=IDENT
    { FieldAccess (e, field) }
  | e=atom { e }
;

subscript_list:
  | subs=separated_nonempty_list(COMMA, subscript) { subs }
;

subscript:
  | start=expr tail=slice_tail
    { match tail with
      | None -> IndexSubscript start
      | Some (stop, step) -> SliceSubscript (Some start, stop, step)
    }
  | COLON stop=option(expr) step=slice_step
    { SliceSubscript (None, stop, step) }
;

slice_tail:
  | (* empty *) { None }
  | COLON stop=option(expr) step=slice_step { Some (stop, step) }
;

slice_step:
  | (* empty *) { None }
  | COLON step=option(expr) { step }
;

atom:
  | n=INT_LIT                   { IntLit n }
  | f=FLOAT_LIT                 { FloatLit f }
  | TRUE                        { BoolLit true }
  | FALSE                       { BoolLit false }
  | s=STRING_LIT                { StringLit s }
  | name=IDENT LPAREN args=separated_list(COMMA, expr) RPAREN
    { Call (name, args) }
  | name=IDENT                  { Var name }
  | LBRACKET elems=separated_list(COMMA, expr) RBRACKET
    { ArrayLit elems }
  | LPAREN e=expr RPAREN        { e }
;

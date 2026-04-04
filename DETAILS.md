# FortScript Transpiler Internals

This document describes the FortScript-to-Fortran transpilation pipeline at
the implementation level. It is intended for contributors who are already
comfortable with compiler-style tooling, parser generators, and modern
Fortran.

## Table of Contents

1. [Pipeline Overview](#1-pipeline-overview)
2. [Lexing: Tokenization and Indentation](#2-lexing-tokenization-and-indentation)
3. [Parsing: AST Construction](#3-parsing-ast-construction)
4. [AST Representation](#4-ast-representation)
5. [Semantic Analysis](#5-semantic-analysis)
6. [Code Generation](#6-code-generation)
7. [Driver Orchestration](#7-driver-orchestration)
8. [Appendix: End-to-End Example](#8-appendix-end-to-end-example)

## 1. Pipeline Overview

FortScript is implemented as a source-to-source compiler. It reads FortScript
source and emits equivalent Fortran source. The pipeline is intentionally
split into distinct stages:

```text
  FortScript source (.py)
        |
        v
  +----------+
  |  Lexer   |   raw text  ->  token stream
  +----------+
        |
        v
  +----------+
  |  Parser  |   tokens  ->  abstract syntax tree (AST)
  +----------+
        |
        v
  +----------+
  | Semantic |   AST  ->  validated AST or error
  | Analysis |
  +----------+
        |
        v
  +----------+
  | Code Gen |   AST  ->  Fortran source text
  +----------+
        |
        v
  Fortran source (.f90)
```

Each stage owns a narrow responsibility. The lexer does not need to know how
Fortran is emitted. The parser does not reason about target-language details.
Only the code generator needs a concrete model of the Fortran surface syntax.
That separation keeps the implementation testable and makes feature work more
predictable.

## 2. Lexing: Tokenization and Indentation

**File:** `lib/lexer.mll` (ocamllex source)

### Scope

The lexer converts raw source characters into a token stream. Tokens are the
input contract for the parser.

For example, the source line:

```python
x: float = 3.14
```

produces:

```text
IDENT("x")  COLON  TFLOAT  EQ  FLOAT_LIT(3.14)  NEWLINE
```

Each token has a tag and, when required, an attached payload. Whitespace
inside a line and comments are consumed without producing tokens.

### Implementation model

The lexer is generated with **ocamllex**. `lib/lexer.mll` defines a set of
pattern/action rules:

```ocaml
| "def"       { DEF }          (* keyword *)
| "+"         { PLUS }         (* operator *)
| digit+ as n { INT_LIT (int_of_string n) }   (* integer literal *)
| alpha alnum* as id { IDENT id }              (* identifier *)
```

When input matches a rule, the action returns the corresponding token.

### Indentation handling

FortScript uses indentation to delimit blocks. Unlike brace-delimited
languages, the lexer must compare the indentation depth of each new line with
the previous active indentation level and synthesize structure tokens for the
parser.

The implementation maintains an **indent stack** containing indentation
columns for active blocks. It is initialized to `[0]`.

At the start of each logical line, the lexer counts leading spaces and
compares the result with the stack top:

- More spaces: push the new level, emit `NEWLINE`, then `INDENT`.
- Fewer spaces: pop until the new level matches the stack top, emitting one
  `DEDENT` per pop. If no matching indentation level exists, the lexer
  reports an inconsistency error.
- Same spaces: emit `NEWLINE`.

For example:

```python
def foo():
    x = 1
    if x > 0:
        y = 2
    z = 3
```

produces, in simplified form:

```text
DEF IDENT("foo") LPAREN RPAREN COLON NEWLINE
INDENT
  IDENT("x") EQ INT_LIT(1) NEWLINE
  IF IDENT("x") GT INT_LIT(0) COLON NEWLINE
  INDENT
    IDENT("y") EQ INT_LIT(2) NEWLINE
  DEDENT
  IDENT("z") EQ INT_LIT(3) NEWLINE
DEDENT
```

The parser therefore operates on explicit block markers rather than raw
whitespace.

### Blank lines, comments, and continuation lines

Three cases receive special handling:

1. Blank lines are skipped and do not affect indentation state.
2. Comment-only lines are skipped.
3. Lines inside `()`, `[]`, or `{}` are treated as continuations.

Continuation handling is implemented with a `paren_depth` counter. While that
counter is positive, newlines are ignored. This supports multi-line calls and
expressions such as:

```python
result = some_function(
    arg1, arg2,
    arg3
)
```

### Pending-token queue

A single indentation transition can yield multiple tokens. For example, one
line boundary may require `NEWLINE` followed by several `DEDENT` tokens. Since
the lexer returns one token per call, extra tokens are staged in a FIFO queue.

```ocaml
let token lexbuf =
  if not (Queue.is_empty pending_tokens) then
    Queue.pop pending_tokens
  else
    main lexbuf
```

The exported wrapper drains the queue before consuming more source input.

## 3. Parsing: AST Construction

**File:** `lib/parser.mly` (Menhir source)

### Scope

The parser consumes the flat token stream and produces the FortScript abstract
syntax tree. The AST captures structural nesting that is not visible in the
token stream itself.

### Implementation model

The parser is generated with **Menhir**. `lib/parser.mly` declares tokens and
grammar productions, with OCaml semantic actions building AST nodes.

Representative rule:

```text
func_def:
  | DEF name=IDENT LPAREN params=separated_list(COMMA, param) RPAREN
    ret=return_annotation COLON NEWLINE INDENT body=stmt_list DEDENT
    { FuncDef { func_name = name; params; return_type = ret; body } }
```

If the parser matches the full sequence, it executes the action and constructs
the corresponding node.

### Precedence encoding

Expression precedence is encoded directly in the grammar rather than delegated
to Menhir precedence declarations. The grammar forms a descending chain of
nonterminals:

```text
expr  ->  or_expr
or_expr  ->  or_expr OR and_expr  |  and_expr
and_expr ->  and_expr AND not_expr  |  not_expr
...
arith  ->  arith PLUS term  |  arith MINUS term  |  term
term   ->  term STAR power  |  term SLASH power  |  power
power  ->  unary DOUBLESTAR power  |  unary
unary  ->  MINUS unary  |  postfix_expr
postfix_expr  ->  postfix_expr [ idx ]  |  postfix_expr . field  |  atom
```

Lower rules bind more tightly than higher ones. `a + b * c ** 2` is therefore
parsed as `a + (b * (c ** 2))`.

### Assignment and expression ambiguity

Python-style syntax creates an ambiguity because both assignments and ordinary
expressions can begin with an identifier:

```python
x = 1
x[0].y = 1
foo(x)
```

The parser resolves this by:

- Reusing `postfix_expr` for assignment targets.
- Prioritizing unambiguous declaration forms before generic assignment and
  expression rules.

```text
simple_stmt:
  | name=IDENT COLON t=typ EQ e=expr    { VarDecl ... }
  | name=IDENT COLON t=typ              { VarDecl ... }
  | target=postfix_expr EQ e=expr       { Assign ... }
  | ...
  | e=expr                              { ExprStmt e }
```

Menhir commits to the first alternative that matches the lookahead stream.

## 4. AST Representation

**File:** `lib/ast.ml`

The AST is the central intermediate representation in the compiler. The parser
produces it, the semantic phase validates it, and the code generator lowers it
to Fortran.

### Top-level declarations

A program is represented as a list of declarations:

```ocaml
type program = decl list

type decl =
  | Import of string
  | StructDef of string * struct_field list
  | FuncDef of func_def
  | GlobalVarDecl of string * typ * expr option
```

### Type model

FortScript types are encoded with the `typ` variant:

```ocaml
type typ =
  | TInt                        (* int    -> integer        *)
  | TFloat                      (* float  -> real(8)        *)
  | TBool                       (* bool   -> logical        *)
  | TString                     (* string -> character(...) *)
  | TFunc of typ list * typ     (* callable[..., ret]       *)
  | TArray of typ * array_dim list
  | TCoarray of typ
  | TStruct of string           (* MyStruct                 *)
  | TVoid                       (* no return value          *)

and array_dim =
  | FixedDim of expr            (* array[float, 10]         *)
  | DeferredDim                 (* array[float] or array[float, :] *)
```

`TArray` stores the element type plus dimension descriptors. Fixed dimensions
retain their bound expressions so cases such as `array[float, n]` remain
available to later phases.

`TCoarray` wraps the scalar or array base type together with codimension
metadata. Examples:

- `float*` becomes `TCoarray (TFloat, [])`.
- `array*[float, :]` becomes `TCoarray (TArray (TFloat, [DeferredDim]), [])`.
- `array*[float, :][:]` becomes `TCoarray (TArray (TFloat, [DeferredDim]), [None])`.

Callable parameters are represented as `TFunc (param_types, return_type)`.
Support is intentionally narrow in the current implementation: callable types
are accepted on function parameters, but not yet on locals, globals, struct
fields, or return positions.

Function parameters also carry an optional default expression. Defaults must
appear only on trailing parameters. The current lowering strategy expands
missing defaults at each call site rather than relying on Fortran `optional`
arguments.

Imports are explicit top-level AST nodes:

```ocaml
type decl =
  | Import of string
  | ...
```

The syntax is minimal by design:

```python
import linear_algebra
import support.linalg
```

### Statements and expressions

The statement layer includes:

- Variable declarations
- Assignments and augmented assignments
- Conditionals
- `for` loops, including `@par` and locality or reduction clauses
- `while` loops
- `return`
- `print`

Expressions include literals, variables, unary and binary operators, calls,
field access, indexing, slicing, and array literals.

Coarray image access is represented explicitly as `CoarrayIndex of expr * expr`.
`shared{0}` is therefore a node whose first child is the coarray expression
and whose second child is the 0-based image expression.

Indexing and slicing share one representation:

```ocaml
type subscript =
  | IndexSubscript of expr
  | SliceSubscript of expr option * expr option * expr option
```

An important design choice is that expressions and assignment targets use the
same structural representation. Targets such as `particles[i].pos.x` or
`u[1:n]` are stored as nested `FieldAccess` and `Index` nodes. The backend
distinguishes read and write contexts with separate lowering paths such as
`gen_expr` versus `gen_lvalue`.

The statement layer also contains dedicated nodes for coarray control:

```ocaml
type stmt =
  | ...
  | SyncAll
  | Allocate of string * expr list
```

`sync` lowers to `SyncAll`. `allocate(buf, n)` stores the target name and the
shape expressions for later translation to Fortran `allocate(...)`.

### Parallel loop metadata

The `for` loop node stores parallelization and clause metadata directly:

```ocaml
type for_block = {
  var: string;
  start_expr: expr;
  end_expr: expr;
  step_expr: expr option;
  for_body: stmt list;
  parallel: bool;
  local_vars: string list;
  local_init_vars: string list;
  reduce_specs: reduction_spec list;
}
```

Stacked annotations above a `for` loop are merged into this record during
parsing. `@par` selects `do concurrent`. `@local(...)`,
`@local_init(...)`, and `@reduce(...)` map to locality and reduction metadata
that is later lowered to Fortran 2018 constructs plus reduction scaffolding.

## 5. Semantic Analysis

**File:** `lib/semantic.ml`

The semantic phase validates conditions that are outside the grammar's scope.
The parser guarantees syntactic structure. Semantic analysis guarantees that
the structure is also admissible for the current language and backend model.

### Recursion detection

FortScript currently rejects both direct and mutual recursion. The analyzer
builds a call graph over user-defined functions and checks it for cycles.

**Step 1: build the call graph.** For each function, traverse its body and
collect the names of user-defined callees:

```text
update_velocities  ->  {compute_distance}
compute_distance   ->  {}
compute_energy     ->  {}
main               ->  {compute_energy, update_velocities, update_positions}
```

Builtins such as `sqrt` or `sin` are excluded because they cannot participate
in user-level recursion.

**Step 2: run DFS cycle detection.** The analysis maintains:

- `visited` for functions already explored completely
- `in_stack` for functions on the active DFS path

Encountering a function already in `in_stack` indicates a cycle:

```text
factorial -> factorial
is_even -> is_odd -> is_even
```

Any cycle is reported as a semantic error.

### Struct validation

The analyzer records all declared struct names and then walks every type
annotation across:

- Struct fields
- Function parameters
- Return types
- Variable declarations

Any `TStruct` reference to an undefined name is rejected.

Array shape annotations are also checked. The language allows either fully
fixed extents or fully deferred extents in a single type, but not a mixture.

### Slice validation

Slice forms are validated after parsing. If the step is a compile-time
constant, it must be positive. This keeps section lowering to Fortran
straightforward and avoids reverse-slice cases that are not currently modeled.

### Plot validation

Plotting is exposed as a statement-only builtin:

```python
plot(x, y, "out.png")
plot(x, y, "out.png", "Title")
plot(x, y, "out.png", "Title", "x", "y")
```

The analyzer rejects `plot(...)` in expression position and enforces argument
counts of 3, 4, or 6.

### Duplicate top-level names

After import expansion, the analyzer checks for duplicate top-level names
across the root file and imported files.

### Coarray validation

The current coarray feature set includes several semantic restrictions:

- Struct fields cannot be coarrays.
- Function parameters and return types cannot be coarrays.
- Deferred-shape coarrays cannot be initialized at declaration time.
- Coarray operations are forbidden inside `@par` loops.

The analyzer treats `shared{img}`, `sync`, `allocate(...)`, `this_image()`,
`num_images()`, and the collective operations (`co_sum`, `co_min`, `co_max`,
`co_broadcast`, `co_reduce`) as part of the coarray feature set when
enforcing those rules.

### Coarray collective operations

Fortran 2018 coarray collectives (`co_sum`, `co_min`, `co_max`,
`co_broadcast`, `co_reduce`) are statement-only subroutines that operate
in-place on their coarray argument across all images. They are rejected
in expression context and lowered to `call co_sum(a)` etc. in the generated
Fortran.

`co_broadcast(a, src)` converts the 0-based FortScript source image index to
Fortran's 1-based indexing automatically.

The operation function passed to `co_reduce` must be pure. The transpiler
detects `co_reduce(a, op)` calls and marks `op` as `pure` through the same
mechanism used for functions called from `do concurrent` blocks.

### Standard-library stub validation

The `support/` proof-of-concept standard library is implemented with ordinary
FortScript stubs recognized by the backend. At present,
`support.linalg.qr`, `support.linalg.solve`, and `support.linalg.svd` are the
main examples:

```python
def qr(a: array[float, :, :], q: array[float, :, :], r: array[float, :, :]):
    pass

def solve(a: array[float, :, :], b: array[float, :], x: array[float, :]):
    pass

def svd(a: array[float, :, :], u: array[float, :, :], s: array[float, :], vt: array[float, :, :]):
    pass
```

When those stubs are present, the analyzer treats `qr(...)`, `solve(...)`,
and `svd(...)` as statement-only operations and checks arity as 3, 3, and 4
arguments respectively.

### Callable and default-argument validation

The semantic phase also validates the function-signature extensions:

- Callable parameters must use non-coarray, non-nested signatures.
- Default values must be trailing-only.
- Default values cannot reference sibling parameters because they are expanded
  at call sites.
- Calls to known user-defined functions and callable parameters are checked for
  arity mismatches, and callable arguments must be passed by name with a
  compatible signature.

## 6. Code Generation

**File:** `lib/codegen.ml`

The backend walks the validated AST and emits Fortran source text. The main
concerns are type lowering, index translation, control-flow mapping, function
signature generation, helper injection, and purity analysis for parallel loops.

### Output structure

Every FortScript translation unit is emitted as a single Fortran module:

```fortran
module fortscript_mod
  implicit none

  ! struct type definitions
  type :: Vec3
    real(8) :: x
    real(8) :: y
    real(8) :: z
  end type Vec3

contains

  ! function and subroutine definitions
  subroutine main()
    ...
  end subroutine main

end module fortscript_mod

program fortscript_main
  use fortscript_mod
  implicit none
  call main()
end program fortscript_main
```

If the FortScript program defines `main`, the backend appends a small driver
program that imports the generated module and calls it.

### Type lowering

FortScript types map to Fortran as follows:

| FortScript | Fortran |
|---|---|
| `int` | `integer` |
| `float` | `real(8)` |
| `bool` | `logical` |
| `string` | `character(len=256)` |
| `callable[array[float, :], float]` | `procedure(fortscript_callable_n__) :: name` |
| `array[float, 10, 10]` | `real(8), dimension(10, 10)` |
| `array[float]` | `real(8), allocatable :: name(:)` or `real(8) :: name(:)` for parameters |
| `float*` | `real(8) :: name[*]` |
| `array*[float, 10]` | `real(8) :: name(10)[*]` |
| `array*[float, :]` | `real(8), allocatable :: name(:)[:]` |
| `array*[float, :][:]` | `real(8), allocatable :: name(:)[:, :]` |
| `MyStruct` | `type(MyStruct)` |
| `void` | subroutine form |

Floating-point literals are emitted with `d0`-style double-precision notation.
`3.14` becomes `3.14d0`, and `1e5` becomes `1d5`.

Callable parameters are lowered through generated `abstract interface` blocks
in the module specification section. Each distinct callable signature receives
a synthetic interface symbol, and the corresponding dummy argument is declared
with `procedure(interface_name)`.

### Indexing and slicing

FortScript uses 0-based indexing. Fortran defaults to 1-based indexing. The
backend therefore adds 1 to every index expression:

```python
a[i] = b[j]
```

```fortran
a(i + 1) = b(j + 1)
```

Compile-time integer indices are folded:

```ocaml
let gen_index_expr e =
  match try_const_int e with
  | Some n -> string_of_int (n + 1)   (* a[0] -> a(1) *)
  | None -> gen_expr e ^ " + 1"       (* a[i] -> a(i + 1) *)
```

Slices are emitted as Fortran array sections. FortScript retains Python-style
exclusive-stop semantics, so the stop bound can be emitted directly while the
start bound is shifted by 1:

```python
window = a[1:4]
a[:2] = 0.0
col = mat[:, 1]
```

```fortran
window = a(2:4)
a(lbound(a, 1):2) = 0.0d0
col = mat(lbound(mat, 1):ubound(mat, 1), 2)
```

Open-ended slices use `lbound` and `ubound`, which makes them valid for both
fixed-shape and deferred-shape arrays. Positive steps are supported:

```text
a[::2] -> a(lbound(a, 1):ubound(a, 1):2)
```

Coarray image selectors follow the same 0-based to 1-based translation:

```python
shared{0}
data[i]{p}
```

```fortran
shared[1]
data(i + 1)[p + 1]
```

### Loop variable convention

Generated loop variables remain 0-based:

```fortran
do i = 0, n - 1
```

This keeps array index translation uniform. If loop variables were shifted to
1-based form in the backend, the code generator would need special-case logic
to detect iterator variables and suppress the normal index offset.

### Struct field lowering

FortScript field access uses dot syntax. Fortran uses `%`:

```text
particle.pos.x  ->  particle%pos%x
```

The generator lowers nested `FieldAccess` nodes recursively.

### Deferred-shape arrays

Deferred-shape arrays are mapped according to declaration context:

- Parameters become assumed-shape dummy arguments.
- Locals, globals, struct fields, and function results become allocatable
  deferred-shape entities.

Examples:

- `x: array[float]` parameter -> `real(8), intent(in) :: x(:)`
- local `x: array[float]` -> `real(8), allocatable :: x(:)`

This allows standard Fortran assignment and reallocation behavior for values
produced by `linspace(...)`, array expressions, or compatible array-valued
calls.

Deferred-shape coarrays follow the same pattern with codimensions:

- `buf: array*[float, :]` -> `real(8), allocatable :: buf(:)[:]`
- `allocate(buf, n)` -> `allocate(buf(n)[*])`

Fixed-size coarrays use `[*]`. Allocatable coarrays use `[:]`.

### Declaration hoisting

Fortran requires declarations at the start of a procedure. FortScript permits
declarations anywhere. The backend resolves that mismatch in two passes:

1. Collect every `VarDecl` in the procedure body, including nested blocks.
2. Emit declarations at the top of the generated procedure.
3. Emit initializers at the original source location.

Example:

```python
def foo():
    a: int = 1
    if a > 0:
        b: float = 2.0
```

becomes:

```fortran
subroutine foo()
  implicit none
  integer :: a
  real(8) :: b

  a = 1
  if (a > 0) then
    b = 2.0d0
  end if
end subroutine foo
```

### Functions versus subroutines

Fortran distinguishes value-returning functions from subroutines. FortScript
does not expose that distinction syntactically, so the backend derives it from
the known return type of each user-defined callable.

Emission rules:

- Non-void call in expression context -> function call
- Void call, or call used as a standalone statement -> `call ...`

Example:

- `result = compute_energy(n, bodies)`
- `call update_positions(n, bodies, dt)`

Functions with return values use `result(...)` syntax:

```fortran
function compute_energy(n, bodies) result(fortscript_result__)
  ...
  fortscript_result__ = energy
  return
end function compute_energy
```

Trailing default arguments are expanded before emission. If FortScript defines:

```python
def foo(x: int, y: int = 1):
```

then `foo(5)` lowers exactly as `foo(5, 1)`.

The `return` statement is initially emitted as an internal marker:

```text
__RETURN__ <value>
```

A post-processing step rewrites that marker to assignment into
`fortscript_result__` followed by `return`.

### Parameter intent inference

The backend infers Fortran `intent` attributes automatically.

Before emitting a procedure, it scans the body for writes that target each
parameter, including nested field and index writes. If a parameter appears on
the left-hand side of an assignment, it is emitted as `intent(inout)`.
Otherwise it is emitted as `intent(in)`.

```ocaml
let rec param_is_modified param_name stmts =
  List.exists (stmt_modifies param_name) stmts

and stmt_modifies pname = function
  | Assign (target, _) -> lvalue_references pname target
  | AugAssign (_, target, _) -> lvalue_references pname target
  | ...
```

### Parallel loops and `do concurrent`

When a `for` loop carries the `parallel` flag, it is lowered to Fortran
`do concurrent`:

```python
@par
for i in range(n):
    c[i] = a[i] + b[i]
```

```fortran
do concurrent (i = 0:n - 1)
  c(i + 1) = a(i + 1) + b(i + 1)
end do
```

FortScript also supports stacked locality and reduction annotations:

```python
@par
@local(tmp)
@local_init(seed)
@reduce(add: total)
@reduce(max: peak)
for i in range(n):
    total += a[i]
```

These lower to Fortran 2018 locality clauses plus reduction scaffolding:

```fortran
block
  real(8), allocatable :: fortscript_reduce_total__1(:)
  real(8), allocatable :: fortscript_reduce_peak__1(:)
  allocate(fortscript_reduce_total__1(n), fortscript_reduce_peak__1(n))
  do concurrent (i = 0:n - 1) local(tmp, total, peak) local_init(seed)
    total = 0.0d0
    peak = -huge(peak)
    ...
    fortscript_reduce_total__1(i + 1) = total
    fortscript_reduce_peak__1(i + 1) = peak
  end do
  total = 0.0d0
  do fortscript_iter__1 = 0, n - 1
    total = total + fortscript_reduce_total__1(fortscript_iter__1 + 1)
  end do
  peak = -huge(peak)
  do fortscript_iter__1 = 0, n - 1
    peak = max(peak, fortscript_reduce_peak__1(fortscript_iter__1 + 1))
  end do
end block
```

`@local(...)` yields `LOCAL(...)`. `@local_init(...)` yields `LOCAL_INIT(...)`.
`@reduce(...)` also uses local storage, initializes each iteration to the
reduction identity, stores per-iteration results in scratch arrays, and then
combines those arrays sequentially after the concurrent region.

The semantic phase enforces that:

- These clauses only appear with `@par`.
- The same variable does not appear in multiple clause categories.
- The loop index is not named explicitly in clause lists.
- The operator matches the target type.

Supported reduction names are `add`, `mul`, `max`, `min`, `iand`, `ior`,
`ieor`, `and`, `or`, `eqv`, and `neqv`. `+` and `*` are accepted as shorthands
for `add` and `mul`.

### Pure-function analysis

Fortran requires procedures called from `do concurrent` regions to be `pure`.
The backend derives that property automatically.

The analysis is:

1. Seed the set with user-defined functions called inside `@par` loop bodies.
2. Compute the transitive closure across user-defined callees.
3. Emit `pure function` or `pure subroutine` for every procedure in the set.

If `update_velocities` contains a parallel loop that calls
`compute_distance`, then `compute_distance` is emitted as:

```fortran
pure function compute_distance(dx, dy, dz) result(fortscript_result__)
```

Coarray operations are excluded from this path by semantic validation, which
keeps generated `do concurrent` regions valid.

### Builtin lowering

FortScript provides a set of NumPy-like builtins that lower directly to
Fortran intrinsics:

| FortScript | Fortran |
|---|---|
| `dot(a, b)` | `dot_product(a, b)` |
| `sum(a)` | `sum(a)` |
| `maxval(a)` | `maxval(a)` |
| `sqrt(x)` | `sqrt(x)` |
| `matmul(a, b)` | `matmul(a, b)` |
| `transpose(m)` | `transpose(m)` |

Some helpers need custom lowering:

- `zeros(n)` -> `spread(0.0d0, 1, n)`
- `ones(n)` -> `spread(1.0d0, 1, n)`
- `linspace(start, stop, n)` -> implied-do array constructor

### Plot helper injection

`plot(...)` is not a Fortran intrinsic. When plotting is used, the backend
injects a helper subroutine into the generated module. That helper:

- Creates a local `type(pyplot)` handle from `pyplot_module`
- Initializes a simple grid-based figure
- Adds a line plot
- Saves the figure to disk through `python3`

The helper template lives in `lib/fortran_helpers.ml` rather than inline in
`lib/codegen.ml`.

### LAPACK-backed helper injection

`support.linalg.qr`, `support.linalg.solve`, and `support.linalg.svd` follow
the same pattern. The FortScript sources under `support/` are pass-only stubs,
but the backend does not emit those stubs as empty procedures. Instead, it
injects helper routines into the generated module and lowers calls directly:

- `qr(a, q, r)` -> `call fortscript_lapack_qr__(a, q, r)`
- `solve(a, b, x)` -> `call fortscript_lapack_solve__(a, b, x)`
- `svd(a, u, s, vt)` -> `call fortscript_lapack_svd__(a, u, s, vt)`

QR helper behavior:

- Copies the input matrix into a local work array
- Calls LAPACK `dgeqrf`
- Extracts the reduced `R` factor
- Calls LAPACK `dorgqr`
- Writes validated results into caller-provided `q` and `r`

SVD helper behavior:

- Copies the input matrix into a local work array
- Calls LAPACK `dgesdd` with `jobz='S'`
- Validates output shapes
- Writes reduced outputs `u(m, k)`, `s(k)`, and `vt(k, n)` where `k = min(m, n)`

Solve helper behavior:

- Checks that `a` is square
- Checks that `b` and `x` both have length `n`
- Copies `a` and `b` because LAPACK overwrites them
- Calls LAPACK `dgesv` with `nrhs = 1`
- Reports singularity when `info > 0`
- Writes the solution into `x`

The helper templates also live in `lib/fortran_helpers.ml`, which keeps
`lib/codegen.ml` focused on lowering decisions.

### Coarray lowering

FortScript coarray constructs lower directly to native Fortran:

- `sync` -> `sync all`
- `this_image()` -> `(this_image() - 1)`
- `num_images()` -> `num_images()`
- `shared{img}` -> `shared[img + 1]`
- `grid[i]{row, col}` -> `grid(i + 1)[row + 1, col + 1]`

Multiple codimensions are declared with an extra bracket after `*`:

```python
buf: array*[float, :][:]         # 2 codims, both deferred
```

Fortran declarations:

| FortScript | Fortran |
|---|---|
| `float*` | `real(8) :: x[*]` |
| `array*[float, :]` | `real(8), allocatable :: x(:)[:]` |
| `array*[float, :][:]` | `real(8), allocatable :: x(:)[:, :]` |
| `array*[float, :, :][:]` | `real(8), allocatable :: x(:,:)[:, :]` |

For allocatable multi-codimension coarrays, the declaration uses deferred
codimension syntax, while actual extents are supplied at allocation time:

```python
allocate(buf, n_local, nrows_p)   # -> allocate(buf(n_local)[nrows_p, *])
```

The backend tracks which visible names are coarrays and the number of extra
codimensions on each symbol so that `allocate` arguments can be split between
array extents and codimension extents correctly.

If a program uses coarrays and defines `main()`, the backend appends a final
`sync all` before returning from `main`.

The updated `examples/coarray_multiple_codims.py` demonstrates a realistic
2D block-decomposed stencil in which each image owns one tile of the global
grid and exchanges edge halos through `[row, col]` coindices before a local
sweep.

`benchmarks/md_mod_coarray.py` uses the same local-array plus exchange-buffer
pattern: particle state is updated in ordinary local arrays and then copied
into a coarray buffer for image-to-image exchange. This stays within the
current restriction that coarray values cannot appear as function parameters
while still exercising the lowering path.

The 2D Laplace benchmarks (`laplace_2d_serial.py`, `laplace_2d_do_concurrent.py`,
`laplace_2d_coarray.py`) solve the Laplace equation on a uniform grid via Jacobi
iteration. The coarray version decomposes the domain into horizontal row bands,
exchanging ghost rows through coarray buffers each iteration, then reduces the
global L1 norm through image 0 for the convergence check.

### Operator lowering

Most operators translate directly:

| FortScript | Fortran |
|---|---|
| `a + b` | `(a + b)` |
| `a ** b` | `(a**b)` |
| `a % b` | `mod(a, b)` |
| `a == b` | `(a == b)` |
| `a != b` | `(a /= b)` |
| `a and b` | `(a .and. b)` |
| `a or b` | `(a .or. b)` |
| `not a` | `(.not. a)` |

`%` lowers to the `mod()` intrinsic because Fortran does not provide it as an
infix arithmetic operator. `!=` becomes `/=`. Logical operators use dotted
Fortran syntax.

## 7. Driver Orchestration

**File:** `bin/main.ml`

The driver coordinates the full pipeline:

1. Parse command-line arguments, including the optional `-o output.f90`.
2. Load the requested source file and recursively expand top-level imports.
3. Apply a once-per-file include guard keyed by normalized source paths.
4. Reset lexer state with `reset_lexer()`.
5. Run `Parser.program token lexbuf`.
6. Run `Semantic.check program`.
7. Run `Codegen.generate program`.
8. Write the generated Fortran to the requested output path or stdout.

Import resolution first checks paths relative to the importing file and then
falls back to the repository root.

The first tokenization step uses `init_and_token` so the lexer enters its
line-start rule and handles indentation on the first line correctly.
Subsequent calls use `token`, which drains the pending-token queue before
resuming normal lexing.

Each stage either produces a value for the next stage or terminates with an
error and a nonzero exit status.

## 8. Appendix: End-to-End Example

Input (`heat.py`):

```python
struct Params:
    dx: float
    alpha: float

def diffuse(p: Params, u: array[float, 100], u_new: array[float, 100], n: int):
    r: float = p.alpha / (p.dx * p.dx)
    @par
    for i in range(1, n - 1):
        u_new[i] = u[i] + r * (u[i + 1] - 2.0 * u[i] + u[i - 1])
```

Lexed token stream, abbreviated:

```text
STRUCT IDENT("Params") COLON NEWLINE INDENT
  IDENT("dx") COLON TFLOAT NEWLINE
  IDENT("alpha") COLON TFLOAT NEWLINE
DEDENT
DEF IDENT("diffuse") LPAREN ... RPAREN COLON NEWLINE INDENT
  IDENT("r") COLON TFLOAT EQ ... NEWLINE
  AT_PAR NEWLINE
  FOR IDENT("i") IN RANGE LPAREN ... RPAREN COLON NEWLINE INDENT
    IDENT("u_new") LBRACKET IDENT("i") RBRACKET EQ ... NEWLINE
  DEDENT
DEDENT
EOF
```

Parsed AST, summarized:

```text
Program [
  StructDef("Params", [dx: float, alpha: float])
  FuncDef {
    name = "diffuse"
    params = [p: Params, u: array[float,100], u_new: array[float,100], n: int]
    return_type = void
    body = [
      VarDecl("r", float, Some(p.alpha / (p.dx * p.dx)))
      For { var="i", start=1, end=n-1, parallel=true,
            local_vars=[], local_init_vars=[], reduce_specs=[],
            body=[Assign(u_new[i], u[i] + r * (u[i+1] - 2.0*u[i] + u[i-1]))] }
    ]
  }
]
```

Semantic result: no recursion; `Params` is defined.

Generated Fortran:

```fortran
module fortscript_mod
  implicit none

  type :: Params
    real(8) :: dx
    real(8) :: alpha
  end type Params

contains

  subroutine diffuse(p, u, u_new, n)
    implicit none
    type(Params), intent(in) :: p
    real(8), dimension(100), intent(in) :: u
    real(8), dimension(100), intent(inout) :: u_new
    integer, intent(in) :: n
    real(8) :: r
    integer :: i

    r = (p%alpha / (p%dx * p%dx))
    do concurrent (i = 1:n - 1 - 1)
      u_new(i + 1) = (u(i + 1) + (r * ((u(i + 1 + 1) - (2.0d0 * u(i + 1))) + u(i - 1 + 1))))
    end do
  end subroutine diffuse

end module fortscript_mod
```

Visible transformations:

- `Params` becomes a Fortran `type`.
- `p.alpha` becomes `p%alpha`.
- `u[i]` becomes `u(i + 1)`.
- `u_new` is inferred as `intent(inout)`.
- `u` is inferred as `intent(in)`.
- `@par` becomes `do concurrent`.
- `2.0` becomes `2.0d0`.
- `r` is declared at the top of the procedure and initialized at its original
  source location.

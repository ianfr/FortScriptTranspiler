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

Loop-exit control flow such as `break` is represented directly in the AST as a
statement node. Semantic validation then checks that it only appears inside
ordinary `for` and `while` loops, since the code generator lowers it to
Fortran `exit`, which is not valid for the `do concurrent` paths used by
`@par` and `@gpu`.

Numerical helper code in the FortScript standard library can also encode
guarded early returns directly in source. The current `support.sparse.cg`
implementation uses that path to avoid dividing by a zero or `NaN` curvature
term during the Conjugate Gradient step-length update.

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
  | TGeneric of string * typ list (* Name[T1, T2, ...]      *)
  | TVoid                       (* no return value          *)

and array_dim =
  | FixedDim of expr            (* array[float, 10]         *)
  | DeferredDim                 (* array[float] or array[float, :] *)
```

`TArray` stores the element type plus dimension descriptors. Fixed dimensions
retain their bound expressions so cases such as `array[float, n]` remain
available to later phases.

`TGeneric` carries a templated type instantiation such as
`CartesianMesh[TemperatureFlow]`. The parser accepts `IDENT[type_args]` in any
type position and stores it as `TGeneric ("CartesianMesh", [TStruct "TemperatureFlow"])`.
The backend monomorphizes each distinct instantiation into its own Fortran
derived type that extends the base struct with one allocatable per
type-parameter struct field. See [CartesianMesh[T] monomorphization](#cartesianmesht-monomorphization)
below.

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
import ./local_helper
import ../examples/linear_algebra
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
  gpu: bool;
  omp: bool;
  local_vars: string list;
  local_init_vars: string list;
  reduce_specs: reduction_spec list;
}
```

Stacked annotations above a `for` loop are merged into this record during
parsing. `@par` selects `do concurrent`. `@omp` selects an OpenMP `parallel do`
instead. `@gpu` marks a parallel loop for separate GPU-kernel extraction.
`@local(...)`, `@local_init(...)`, and `@reduce(...)` map to locality and
reduction metadata that is later lowered to Fortran 2018 constructs plus
reduction scaffolding for `@par`, or to OpenMP `private`/`firstprivate`/
`reduction` clauses for `@omp`.

## 5. Semantic Analysis

**Files:** `lib/semantic.ml` (entry point), `lib/semantic_types.ml`,
`lib/semantic_calls.ml`, `lib/semantic_decls.ml`, `lib/semantic_parallel.ml`,
`lib/semantic_builtins.ml`

The semantic phase validates conditions that are outside the grammar's scope.
The implementation is split across sibling modules:

- `semantic_types.ml`: shared types, sets/maps, type predicates, and
  standard-library stub detectors
- `semantic_calls.ml`: call-graph construction and recursion (cycle)
  detection
- `semantic_decls.ml`: struct, callable, and call-site validation; duplicate
  top-level name checks
- `semantic_parallel.ml`: coarray, `do concurrent` clause, `@gpu` loop, and
  `break` scoping validation, plus `validate_omp_loop_safety`, a race check that
  reports two `@omp` patterns as errors: (1) a scalar read before it is assigned
  (an undeclared reduction or sequential dependence that auto-privatization would
  silently hide), and (2) an array written at one index and read at a different
  index where the differing index position varies with something other than an
  inner sequential loop variable (a loop-carried array dependence such as a
  stencil reading its own output). The user annotates with `@reduce`/`@local_init`
  to assert intent. Both are AST walks; FortScript loops are simple enough that a
  polyhedral dependence library is unwarranted
- `semantic_builtins.ml`: slice constraints and per-builtin shape checks for
  plotting, HDF5, XDMF, and `support.linalg`/`support.random` stubs
- `semantic.ml`: composes the validators in order and exposes `check` and
  the `SemanticError` exception

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

### Append builtin validation

`append(arr, val)` is a statement only builtin for ordinary 1D deferred-shape
arrays. The semantic pass rejects expression uses, non-variable targets,
function parameters, coarrays, fixed-shape arrays, multidimensional arrays,
and unsupported element types. The first argument must already be declared in
the current function or as a global.

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

### GPU-loop validation

`@gpu` loops are checked separately from ordinary `@par` loops.

The current semantic rules are:

- `@gpu` must also be paired with `@par`
- Coarray operations are forbidden inside `@gpu` loops
- Array references inside `@gpu` loops are currently limited to rank-1 and rank-2 arrays

User-defined helper calls are allowed. The compiler already computes the set
of functions that must be marked `pure` for `do concurrent`, and the same
call-graph machinery is reused for GPU-extracted helper procedures.

### Standard-library stub validation

The `support/` proof-of-concept standard library is implemented with ordinary
FortScript modules. Some entries are backend-recognized stubs, while others
such as `support.optimize`, `support.sparse`, `support.geom_cartesian_fvm`,
and most of `support.geom_stl` and `support.geom_cartesian` are emitted as
normal FortScript code. At
present, `support.linalg.qr`, `support.linalg.solve`, `support.linalg.svd`,
`support.linalg.eig`, `support.random.random_fill`,
`support.random.uniform_fill`, `support.random.seed`,
`support.geom_stl.geom_stl_read_ascii`, and
`support.geom_stl.geom_stl_read_binary` are the main stub examples. The two
`geom_stl_read_*` stubs lower to subroutine calls into the hand-written
Fortran module `support/geom_stl_read.f90`, which the compiler emits a
`use geom_stl_read_mod` for; the rest of the geom support code is pure
FortScript:

```python
def qr(a: array[float, :, :], q: array[float, :, :], r: array[float, :, :]):
    pass

def solve(a: array[float, :, :], b: array[float, :], x: array[float, :]):
    pass

def svd(a: array[float, :, :], u: array[float, :, :], s: array[float, :], vt: array[float, :, :]):
    pass

def eig(a: array[float, :, :], wr: array[float, :], wi: array[float, :], vr: array[float, :, :]):
    pass

def random_fill(x: array[float, :]):
    pass

def uniform_fill(low: float, high: float, x: array[float, :]):
    pass

def seed(s: int):
    pass
```

When those stubs are present, the analyzer treats `qr(...)`, `solve(...)`,
`svd(...)`, `eig(...)`, `random_fill(...)`, `uniform_fill(...)`, and
`seed(...)` as statement-only operations and checks arity as 3, 3, 4, 4, 1,
3, and 1 arguments respectively.

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

**Files:** `lib/codegen.ml` (entry point), `lib/codegen_state.ml`,
`lib/codegen_analysis.ml`, `lib/codegen_types.ml`, `lib/codegen_expr.ml`,
`lib/codegen_stmt.ml`, `lib/codegen_proc.ml`, `lib/codegen_program.ml`

The backend walks the validated AST and emits Fortran source text. The main
concerns are type lowering, index translation, control-flow mapping, function
signature generation, helper injection, and purity analysis for parallel loops.

The implementation is split across sibling modules:

- `codegen_state.ml`: shared mutable state (hashtables, counters, feature
  flags), builtin name tables, stub detectors, the `gpu_kernel_artifact` and
  `generated_output` record types, and the `gen_expr_ref` / `gen_procedure_ref`
  forward-reference thunks that bridge layers below
- `codegen_analysis.ml`: program walks for call/reference collection,
  reachability, purity inference, variable scanning, and GPU-kernel parameter
  extraction
- `codegen_types.ml`: callable signature keys, index/slice lowering, the
  mutually recursive Fortran type-declaration block, reduction helpers, and
  AST renaming
- `codegen_expr.ml`: expression codegen (`gen_expr`, `gen_binop`, `gen_call`)
  and the per-builtin standalone-statement emitters (`gen_plot_stmt`,
  `gen_h5_stmt`, `gen_lapack_*_stmt`, and so on); registers `gen_expr_ref` at
  the end
- `codegen_stmt.ml`: parameter-modification analysis, GPU-kernel parameter
  marshaling, and the `gen_stmt` / `gen_stmt_core` / `gen_stmts_into` /
  `gen_lvalue` / `gen_gpu_kernel_call` mutual-recursion block
- `codegen_proc.ml`: local-declaration collection, procedure preamble and
  body emission, `gen_procedure` itself, GPU interface generation, and
  abstract-interface synthesis for callable parameter types; registers
  `gen_procedure_ref` at the end
- `codegen_program.ml`: whole-program walks that decide which support
  helpers must be emitted (`program_uses_plotting`, `program_uses_h5`,
  `program_uses_coarrays`, and so on) and the struct-type emitter
- `codegen.ml`: composes the modules, re-exports `gpu_kernel_artifact` and
  `generated_output`, and contains `generate_output` and `generate`

The two forward-reference refs (`gen_expr_ref`, `gen_procedure_ref`) exist
because `codegen_types` needs to call `gen_expr` (defined later in
`codegen_expr`) and `codegen_stmt.gen_gpu_kernel_call` needs to call
`gen_procedure` (defined later in `codegen_proc`). OCaml's module
initialization order ensures both refs are populated before any call into
`Codegen.generate_output`.

When `@gpu` loops are present, the backend also emits one extra `_gpu.f90`
translation unit per extracted GPU kernel. The host output keeps the original
procedure structure, but the `@gpu` loop itself lowers to a call to an
external kernel subroutine.

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

### Append lowering

`append(arr, val)` lowers to a local Fortran `block` with a temporary
allocatable array. If `arr` is already allocated, codegen allocates the
temporary at `size(arr) + 1`, copies the existing elements, writes `val` into
the final slot, and transfers ownership with `move_alloc`. If `arr` is not
allocated, codegen allocates `arr(1)` and assigns the value directly.

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

### `CartesianMesh[T]` monomorphization

The `support.geom_cartesian` module ships a templated `CartesianMesh[FieldSet]`
type. The user defines a "field set" struct whose members name the per-cell
quantities, and writes `mesh: CartesianMesh[TemperatureFlow]`. The backend
materializes that into a Fortran derived type at code generation time.

The pipeline:

1. **Parse** -> `name=IDENT LBRACKET type_args RBRACKET` produces
   `TGeneric (name, args)`. The grammar accepts this in any type position.
2. **Collect** -> `Codegen_program.collect_generic_instantiations` walks the
   program looking for any `TGeneric` used in a variable, parameter, return,
   field, or nested type. It deduplicates by base name plus stringified args
   and returns the instantiations in source order.
3. **Emit** -> `Codegen_program.gen_generic_instantiation` writes one Fortran
   derived type per instantiation, immediately after the base struct
   definitions. The emitted type uses `extends(<base>)` so the inherited
   mesh metadata and cell-list arrays remain accessible, then adds one
   allocatable per field of the type-parameter struct:

   - `float` field -> rank-1 `real(8) :: <name>(:)`
   - `array[float, 3]` field -> rank-2 `real(8) :: <name>(:,:)`
   - other field types -> emitted as a comment and skipped

4. **Name lowering** -> `Codegen_types.monomorphized_type_name` builds the
   derived-type name as `<base_lower>_<arg_lower>` (e.g. `cartesianmesh_temperatureflow`).
   `fortran_type` returns `type(<monomorphized_name>)` whenever it encounters
   a `TGeneric`, so variable declarations of `CartesianMesh[TemperatureFlow]`
   lower to `type(cartesianmesh_temperatureflow) :: name`.

Field reads and writes on a templated mesh are not built-in: because each
field-set field becomes a real derived-type component, the standard
`FieldAccess` / `Index` / `Assign` codegen paths handle `mesh.temperature`,
`mesh.temperature[c]`, `mesh.pressure[:] = 101325.0`, and so on with no
special cases.

A support routine that accepts a parameter of a struct type which serves as the
base of a `TGeneric` instantiation (currently only `CartesianMesh`) lowers that
dummy argument as polymorphic `class(Base)` when an `intent` is present. This
lets ordinary support modules such as `support.geom_cartesian` accept
monomorphized extension values like `CartesianMesh[HeatField]`. The codegen
records these base names from `collect_generic_instantiations`
(`generic_base_names` / `is_generic_base` in `Codegen_state`).

Every other struct parameter lowers to a non-polymorphic `type(Base)` dummy,
because FortScript has no user-level inheritance, so the actual argument always
matches the dummy type exactly. The `type(...)` form is preferred over
`class(...)` because a polymorphic class dummy carries a `_data`/`_vptr`
indirection that GCC's `do concurrent` autopar treats as a non-affine base,
which blocks parallelization of loops that write a struct component such as
`eq%diag(c)`. Using `type(...)` keeps those component writes affine. Local
variables and function results already lower to concrete `type(...)`
declarations.

The main piece the FortScript layer cannot express is the per-instantiation
allocation of the per-field arrays. Construction is compiler-lowered for the
templated form:

- `geom_cartesian_uniform(mesh, dim_min, dim_max, spacing)` is
  detected in `Codegen_stmt` and dispatched to `gen_geom_cartesian_uniform_stmt`.
  The emitter resolves the mesh argument's type-parameter struct via the
  `user_structs` registry (`resolve_cartesian_template`), assigns the metadata
  fields, allocates root-grid cell-list storage, fills geometry and same-level
  neighbor ids, and emits one `allocate(mesh%<f>(...))` per FieldSet field.
  Calling it with a non-templated mesh is a hard error at code-generation time.
- `geom_cartesian_refine_cell(mesh, cell_id)` is also compiler-lowered. It
  grows the mesh arrays when needed, appends eight child cells, copies each
  FieldSet value from the parent to the children, updates `leaf_ids`, and
  rebuilds the face-neighbor table by calling `geom_cartesian_rebuild_neighbors`.
  The per-child split body is shared with the other refine helpers through the
  `emit_refine_one_parent` emitter.
- `geom_cartesian_refine_to_sdf(mesh, sdf, tol, max_level)` is lowered for
  the same reason. It resolves the FieldSet arrays, samples the rank-3 SDF
  grid with trilinear interpolation, refines one matching leaf per pass, and
  repeats until no leaf center within `tol` remains below `max_level`.
- `geom_cartesian_refine_band(mesh, sdf, tol, max_level)` is the batched
  surface-refinement primitive, modeled on the castellation stage of
  snappyHexMesh. `sdf` is a per-cell scalar field. Each pass marks every leaf
  below `max_level` with `abs(sdf) <= tol`, then propagates 2:1 balance over the
  marked set with an explicit integer worklist (`fs_stack__`), reading the
  current neighbor table. It splits the whole marked batch in one loop (sharing
  `emit_refine_one_parent`), grows capacity once for `8 * nmark` children,
  recompacts `leaf_ids` by scanning `is_leaf`, and calls
  `geom_cartesian_rebuild_neighbors` once. Passes repeat until nothing is
  marked. This replaces the per-cell refine + per-cell neighbor rebuild loop,
  dropping the cost from `O(R * N^2)` to `O(L * N * tree_depth)`.
- `geom_cartesian_coarsen_cell(mesh, cell_id)` is compiler-lowered as the
  inverse operation for a parent whose eight children are active leaves. It
  averages FieldSet values into the parent, reactivates the parent leaf, marks
  the children inactive, rebuilds `leaf_ids`, and rebuilds neighbors.

`geom_cartesian_rebuild_neighbors(mesh)` is a plain FortScript function (not
compiler-lowered) in `support/geom_cartesian.py`. Because it touches only the
base `CartesianMesh` topology fields and not the FieldSet arrays, it works for
any `CartesianMesh[T]` instantiation through the `class(CartesianMesh)` dummy
argument. It refills the per-face neighbor table by locating the four
sub-quadrant probe points just outside each leaf face with
`geom_cartesian_locate`, which is exact on a 2:1 graded cartesian mesh and runs
in `O(num_leaves * tree_depth)`. This replaced the earlier inline all-pairs
`O(num_leaves^2)` overlap scan that the lowered helpers used to emit.

The FortScript-side `def geom_cartesian_uniform(...)` and other cartesian
mutation helpers in `support/geom_cartesian.py` are `pass` stubs. They exist
so the semantic phase has signatures to check arity against; the actual body
is whatever the codegen built-in emits per instantiation.

Small topology helpers such as `geom_cartesian_face_neighbor_kind`,
`geom_cartesian_face_center`, and `geom_cartesian_face_normal` are also lowered
directly when needed so they work with any `CartesianMesh[T]` instantiation.
`geom_cartesian_locate` and `geom_cartesian_find_imbalance` are plain FortScript
functions over the base `CartesianMesh` topology, callable from both user code
and the lowered helpers.

`support.geom_cartesian_fvm.fvm_equation_init` is lowered directly as well,
because FortScript's `allocate(...)` statement currently accepts only bare
variable names and cannot allocate struct components such as `eq.diag` from
ordinary support-library source.

`geom_cartesian_sample_sdf` is a plain FortScript function (not compiler-
lowered). It accepts explicit coordinate arrays `x_sdf`, `y_sdf`, `z_sdf`
and their dimension counts `nx_sdf`, `ny_sdf`, `nz_sdf` because FortScript
does not expose an intrinsic array-size function. The SDF grid must use
z-major storage (`sdf_grid[k, j, i]` = value at `x[i], y[j], z[k]`), matching
the convention of `geom_cartesian_refine_to_sdf`. Uniform grid spacing is
assumed; the spacing is derived from the first two elements of each coordinate
array.

For immersed-body FVM, `fvc_sample_sdf_from_stl` (in
`support.geom_cartesian_fvm`) bypasses this grid path entirely: it queries the
exact STL distance at each leaf center with `geom_stl_sdf_point`, a pure
function over a prebuilt `STLBins`. The per-point body (bin-shell nearest search
plus off-axis ray parity) was factored out of `geom_stl_sdf_uniform`, which now
calls `geom_stl_sdf_point` for every grid node, so the grid and direct paths
share one implementation. The bins depend only on the STL, so a single
`geom_stl_build_bins` call (sized by `geom_stl_sdf_nbin`) is reused for the
initial sample and every refinement pass. This removes the SDF-grid resolution
limit on the body geometry (no trilinear interpolation smoothing) and is cheaper
than a high-resolution grid because only the leaf centers are sampled.

#### Face flux sign convention in `support.geom_cartesian_fvm`

All `phi_face` arrays in the BDIM and PIMPLE helpers use the **outward flux
convention**: `phi[c, f] > 0` means net volumetric flux leaving cell `c`
through face `f`. Even-indexed faces (0, 2, 4 = -x, -y, -z direction faces)
have outward normals pointing in the negative axis direction, so a uniform
positive x-velocity produces `phi[c, 0] < 0` (inflow through the -x face) and
`phi[c, 1] > 0` (outflow through the +x face). `fvc_div_flux` sums all six
aggregate face fluxes and divides by cell volume; the result is zero for any
incompressible uniform field. On adaptive meshes, `fvc_face_slot_area` maps
each face-neighbor slot to its represented area. Same-level, coarser-neighbor,
and boundary faces use the full face area in slot 0; coarse-to-fine faces use
one quarter of the face area per slot. The FVM Laplacian, upwind convection,
velocity flux, and pressure flux correction use the same slot areas so the
pressure matrix and corrected face flux stay consistent on hanging faces.
For pressure-velocity coupling on adaptive meshes, the `_invA` pressure
helpers interpolate cell `invA` per face-neighbor slot instead of reusing one
face value for every subface.

#### Static immersed body PIMPLE example

`examples/support_geom_cartesian_fvm_body_pimple.py` demonstrates a
BDIM-PIMPLE solver for flow past a static STL body. The first version
supports static bodies only (prescribed body velocity = 0), no turbulence
model, and no force integration. The pressure-velocity coupling forms
`HbyA = H(u) / A` from the assembled momentum equation and carries the
pressure-corrected face flux into the next momentum predictor. The inflow
velocity is applied to both diffusion and upwind convective inflow terms.
Moving bodies, nonzero prescribed velocity, force integration, and validation
benchmarks are left for future work.

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

### GPU kernel extraction

For a `@gpu` loop, code generation takes three steps:

1. Collect the loop's free variables and turn them into kernel parameters.
2. Emit a call from the host procedure to an external GPU-kernel subroutine.
3. Emit a standalone `_gpu.f90` file containing that kernel subroutine, plus
   any user-defined pure helper procedures reachable from the loop body.

The kernel source still uses `do concurrent`, but it is compiled separately
with `nvfortran -stdpar=gpu`.

One important implementation detail is the mixed-compiler ABI boundary.
Passing assumed-shape arrays directly between `gfortran` and `nvfortran`
caused runtime crashes because the compilers use incompatible array-descriptor
representations. To avoid that, the generated GPU interface uses:

- explicit dimension integers such as `x_dim1`, `y_dim1`
- explicit-shape array dummies such as `x(x_dim1)` and `y(y_dim1)`

The host side passes `size(x, 1)` / `size(y, 1)` alongside the arrays, so the
boundary is descriptor-free.

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

Every scalar that is assigned in the loop body is added to a `local(...)` clause
automatically, even when the loop carries no explicit `@local` annotation. This
keeps GCC's autopar from treating a procedure-scope scalar temporary as a
loop-carried dependence. A scalar whose first reference in the body is an
unconditional whole-variable write becomes a plain `local`; any other case
(read before written, or first written inside a conditional or inner loop) uses
`local_init` so the iteration carries the pre-loop value in. Inner sequential
loop variables are made `local` as well.

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

### OpenMP loops via `@omp`

`@omp` is a drop-in replacement for `@par`. Where `@par` lowers to
`do concurrent`, `@omp` lowers to an OpenMP `parallel do` emitted in place, so
the generated subroutine is otherwise identical:

```python
@omp
for l in range(mesh.num_leaves):
    c = mesh.leaf_ids[l]
    out[c] = a[mesh.neighbor[c, 0, 0]]
```

```fortran
!$omp parallel do default(shared) private(c)
do l = 0, mesh%num_leaves - 1
  c = mesh%leaf_ids(l + 1)
  out(c + 1) = a(mesh%neighbor(c + 1, 1, 1) + 1)
end do
!$omp end parallel do
```

The motivation is that GCC's `do concurrent` autopar refuses any loop whose
memory references are not affine, which rules out neighbor-gather stencils such
as `a(neighbor(...))`. An OpenMP worksharing directive parallelizes the loop by
construction with no dependence analysis, so the same loop body runs on CPU
threads under gfortran `-fopenmp`. The `-fopenmp` flag is already on the build
command, so `@omp` needs no new toolchain.

The same automatic scalar collection used for `@par` `local()` drives the
OpenMP clauses: scalars written before being read become `private`, scalars
carried in from before the loop become `firstprivate`, inner sequential loop
variables become `private`, and explicit `@reduce(op: vars)` maps to a native
`reduction(op:vars)` clause (no per-iteration scratch array, unlike the `@par`
reduction path). The loop index is private by default under worksharing.

Getting the private set complete is a correctness requirement: a scalar that is
shared by mistake is a data race rather than a compile error. The collection
covers every whole-variable assignment target in the body, including those
nested in conditionals and inner loops.

The element-wise FVM kernels in `support.geom_cartesian_fvm` stay on `@par` and
iterate the dense cell-id space so their writes are affine; the stencil kernels
that read `mesh.neighbor` use `@omp`. The two mechanisms target different loops
and the build runs both `-fopenmp` and `-ftree-parallelize-loops`.

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

The helper template lives in `lib/fortran_helpers_plot.ml` rather than inline
in the code generator. Plotting, linear-algebra, and core Fortran helper
templates are split across `lib/fortran_helpers.ml` (core utilities and HDF5/
XDMF templates), `lib/fortran_helpers_plot.ml` (`pyplot-fortran`-backed plot
emitters), and `lib/fortran_helpers_linalg.ml` (LAPACK and random-number
wrapper subroutines).

### LAPACK-backed helper injection

`support.linalg.qr`, `support.linalg.solve`, `support.linalg.svd`, and
`support.linalg.eig` follow the same pattern. The FortScript sources under
`support/` are pass-only stubs, but the backend does not emit those stubs as
empty procedures. Instead, it injects helper routines into the generated
module and lowers calls directly:

- `qr(a, q, r)` -> `call fortscript_lapack_qr__(a, q, r)`
- `solve(a, b, x)` -> `call fortscript_lapack_solve__(a, b, x)`
- `svd(a, u, s, vt)` -> `call fortscript_lapack_svd__(a, u, s, vt)`
- `eig(a, wr, wi, vr)` -> `call fortscript_lapack_eig__(a, wr, wi, vr)`

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

Eig helper behavior:

- Checks that `a` is square `(n, n)`
- Checks that `wr` and `wi` both have length `n` and that `vr` is `(n, n)`
- Copies `a` because LAPACK overwrites it
- Calls LAPACK `dgeev` with `jobvl='N', jobvr='V'`
- Writes real and imaginary eigenvalue parts into `wr` and `wi`
- Writes right eigenvectors into `vr` using LAPACK packed layout (real
  eigenvalues use a single column; complex conjugate pairs occupy two
  consecutive columns holding the real and imaginary parts)

Solve helper behavior:

- Checks that `a` is square
- Checks that `b` and `x` both have length `n`
- Copies `a` and `b` because LAPACK overwrites them
- Calls LAPACK `dgesv` with `nrhs = 1`
- Reports singularity when `info > 0`
- Writes the solution into `x`

The LAPACK and random helper templates live in
`lib/fortran_helpers_linalg.ml`, which keeps the codegen modules focused on
lowering decisions.

### Random number generation (prand)

`support.random` is backed by the [prand](https://github.com/cheng-zhao/prand)
parallel RNG C library through the hand-written Fortran wrapper
`support/prand_mod.f90`, rather than by injected helper bodies. prand exposes a
heap-allocated `prand_t` struct whose sampling routines are C function pointers.
There is no C shim: `prand_mod` mirrors that struct as a `bind(c)` derived type,
binds `prand_init` / `prand_destroy` directly with `iso_c_binding`, and calls the
function pointers through `c_f_pointer` (to view the struct) and
`c_f_procpointer` (to invoke `get_double`). The module keeps two generators as
module state: a single-stream serial generator and a multi-stream generator with
one stream per OpenMP thread.

Like the LAPACK and STL-reader stubs, the `support.random` functions are
pass-only stubs. The backend detects them
(`is_random_fill_stub`, `is_random_seed_stub`, `is_prand_uniform_stub`,
`is_prand_uniform_thread_stub`, `is_prand_seed_parallel_stub`, etc. in
`Codegen_state`), suppresses the empty FortScript procedures, emits
`use prand_mod` once at module scope (like `use geom_stl_read_mod`), and lowers
calls directly:

- `seed(s)` -> `call fortscript_random_seed__(s)`
- `random_fill(x)` -> `call fortscript_random_fill__(x)`
- `uniform_fill(low, high, x)` -> `call fortscript_uniform_fill__(low, high, x)`
- `prand_seed_parallel(s)` -> `call fortscript_prand_seed_parallel__(s)`
- `prand_uniform()` -> `fortscript_prand_uniform__()` (value-returning)
- `prand_uniform_thread()` -> `fortscript_prand_uniform_thread__()` (value-returning)

`prand_uniform_thread` reads the OpenMP thread id (`omp_get_thread_num`) to pick
its stream, so it is impure and intended for `@omp` loops, not `@par`
(`do concurrent`) loops. The build links the prand static library (`libprand.a`)
and compiles `prand_mod.f90` alongside the generated source, the same way
`geom_stl_read.f90` is compiled for the STL reader.

### HDF5 builtin lowering

`h5write` and `h5read` are statement-only builtins that lower directly to the
generic procedures from the [h5fortran](https://github.com/geospace-code/h5fortran)
high-level interface. The semantic pass enforces arity 3 and rejects use in
expression position; the code generator then emits a plain `call`:

- `h5write(file, "/x", x)` -> `call h5write(file, "/x", x)`
- `h5read(file, "/x", x)`  -> `call h5read(file, "/x", x)`

When any HDF5 builtin appears anywhere in the program, the backend injects a
single `use h5fortran, only: h5write, h5read` line at the top of the generated
`fortscript_mod` module. Host association makes the generic procedures visible
to every contained subroutine, so no per-call helper template is needed -- the
generic dispatch on rank/type is handled by h5fortran itself.

`h5read` writes into its third argument, so deferred-shape destinations must be
allocated to match the on-disk dataset shape before the call. The lowering only
handles dataset reads and writes. Higher-level metadata for downstream
consumers, such as an XDMF sidecar for ParaView, is handled separately from the
raw HDF5 calls.

### XDMF builtin lowering

`xdmf_add`, `xdmf_add_xyz`, and `xdmf_write` are statement-only builtins that
lower to generated helper subroutines inside the emitted `fortscript_mod`
module:

- `xdmf_add(xml, name, a)` -> `call fortscript_xdmf_add__(xml, name, a)`
- `xdmf_add_xyz(xml, x, y, z)` -> `call fortscript_xdmf_add_xyz__(xml, x, y, z)`
- `xdmf_write(xdmf_file, h5_file, xml)` -> `call fortscript_xdmf_write__(xdmf_file, h5_file, xml)`

The generated helpers build XML strings using deferred-length Fortran character
variables and write the final `.xdmf` file directly. The current implementation
targets 3D rectilinear grids for ParaView. `xdmf_add` accepts rank-3 integer
and `real(8)` arrays, while `xdmf_add_xyz` accepts rank-1 integer and `real(8)`
coordinate arrays.

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

The shallow water benchmarks (`shallow_water_serial.py`,
`shallow_water_do_concurrent.py`, `shallow_water_coarray.py`) port the compute
kernel from `benchmarks/python/shallow_water.py`. The serial and `do concurrent`
variants compute face fluxes inline and ping-pong between two field buffers. The coarray
variant decomposes the 2D domain into a 2D image grid, keeps compute fields in
ordinary local arrays, exchanges `eta`, `u`, and `v` edges through multi-codim
coarray halo buffers, ping-pongs between two local field buffers, and reduces
final checksums with `co_sum`. Its image coordinate mapping follows Fortran
coarray ordering for `[nrows_p,*]`, so the first coindex is the fastest-varying
coordinate.

The 3D Ising coarray benchmark keeps the spin slab in ordinary local memory and
uses coarray plane inboxes only for neighbor exchange. Ghost-plane exchange uses
direct remote writes into double-buffered inboxes, which avoids remote reads in
the hot sweep path and removes the second synchronization from each exchange.

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
7. Run `Codegen.generate_output program`.
8. Write the main generated Fortran to the requested output path or stdout.
9. If GPU kernels were extracted, write each emitted `_gpu.f90` artifact next
   to the requested output file.

Bare imports first check paths relative to the importing file and then fall
back to the repository root. Path-style imports that start with `./` or
`../` remain anchored to the importing file.

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

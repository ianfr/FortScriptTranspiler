# Language Reference

## Types

`int`, `float`, `bool`, `string`, `void`, `array[T, dims...]`, `callable[T1, ..., TRet]`, `float*`, `array*[T, dims...]`, struct names

### Dynamic Arrays

Dynamic arrays use deferred-shape syntax:

```python
values: array[float]
matrix: array[float, :, :]
def axpy(a: float, x: array[float], y: array[float]) -> array[float]:
```

Deferred-shape parameters become assumed-shape Fortran dummy arguments, and deferred-shape locals, globals, struct fields, and function results become allocatable arrays.

### Callable Parameters

Callable parameters use the final type as the return type:

```python
def minimize_nelder_mead(
    func: callable[array[float, :], float],
    x0: array[float, :],
    lower: array[float, :] = zeros(0),
    upper: array[float, :] = zeros(0)
):
```

Trailing parameters may have default values. The transpiler expands omitted
arguments at call sites, so `minimize_nelder_mead(f, x0)` and
`minimize_nelder_mead(f, x0, lower, upper)` both work.

### Coarray Types

Coarray types use a `*` suffix. An extra bracket after `*` adds leading codimensions before the implicit final `*`/`:`, enabling a 2D (or higher) process grid:

```python
shared: float*              # 1 codim: [*]
data: array*[float, 100]    # 1 codim: (100)[*]
buf: array*[float, :]       # 1 codim, deferred: (:)[:]
grid: array*[float, :][:]   # 2 codims, both deferred: (:)[:,:]
```

The codim bracket accepts `:` (deferred, for allocatable coarrays) or integer expressions (fixed, for static coarrays). Deferred extra codims are allocated via `allocate`; the sizes appear as trailing arguments after the array dimensions:

```python
grid: array*[float, :][:]
allocate(grid, n_local, nrows_p)   # -> allocate(grid(n_local)[nrows_p,*])
```

Multi-codim coarray access uses comma-separated indices inside `{}`:

```python
val = buf[0]{row, col}             # -> buf(1)[row+1, col+1]
```

## Array Access

`a[i]`, `a[i, j]`, `a[start:stop]`, `a[:stop]`, `a[start:]`, `a[::step]`, `a[1:4] = 0.0`, `a[:, 1]`, `shared{img}`, `data[i]{img}`, `grid[i]{row, col}`

Slice bounds follow Python-style 0-based, exclusive-stop semantics. Slice steps must be positive when statically known.

## Builtins

`dot`, `sum`, `product`, `minval`, `maxval`, `abs`, `sqrt`, `sin`, `cos`, `tan`, `exp`, `log`, `matmul`, `transpose`, `reshape`, `zeros`, `ones`, `linspace`, `arange`, `this_image`, `num_images`, `co_sum`, `co_min`, `co_max`, `co_broadcast`, `co_reduce`

## Standard Library

### `support.linalg`

Mimics `numpy.linalg`. Current LAPACK-backed helpers:

- `qr(a, q, r)` -- reduced QR with caller-provided outputs
- `solve(a, b, x)` -- square `A x = b` systems with a vector right-hand side
- `svd(a, u, s, vt)` -- reduced SVD with caller-provided outputs

These helpers lower to generated LAPACK wrappers and are statement-only today, so the caller preallocates the output arrays before calling them. The default `FFLAGS` from `env-setup.sh` already include `-llapack -lblas`.

### `support.optimize`

Mimics `scipy.optimize.minimize` with Nelder-Mead implemented purely in FortScript.

- `minimize_nelder_mead(func, x0, lower=zeros(0), upper=zeros(0))` returns an `OptimizeResult`

`OptimizeResult` exposes:
- `x` -- the best point found
- `fun` -- the objective value at `x`
- `nit` -- the iteration count
- `nfev` -- the number of function evaluations
- `success` -- convergence status
- `status` -- integer code (`0` success, `1` iteration limit, `-1` invalid input)

## Imports

Top-level `import some_library`, `import support.linalg`

Imports are resolved relative to the importing file first, then from the repository root. This makes it possible to keep light standard-library modules under `support/`. Each source file is expanded at most once, so repeated or transitive imports of the same file do not redefine its contents.

## Loops

`for i in range(...)` with optional `@par`, `@local(...)`, `@local_init(...)`, and `@reduce(op: vars...)` annotations, `while`

## Control Flow

`if`/`elif`/`else`, `return`, `pass`, `sync`, `allocate(name, dims...)`

## Operators

`+`, `-`, `*`, `/`, `%`, `**`, `==`, `!=`, `<`, `>`, `<=`, `>=`, `and`, `or`, `not`, `+=`, `-=`, `*=`, `/=`

## Plotting

`plot(x, y, "out.png")`, `plot(x, y, "out.png", "Title")`, `plot(x, y, "out.png", "Title", "x", "y")`

`plot(...)` is a statement-only builtin. It generates a single line plot and saves it to disk through `pyplot-fortran`. Runtime plotting currently expects `python3` with `matplotlib` installed.

## Notes

For a single-image local sanity check when using coarrays, plain `gfortran -fcoarray=single` is also sufficient.

See [DETAILS.md](DETAILS.md) for a full explanation of how the transpiler works.

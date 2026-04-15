# Language Reference

## Loops

`for i in range(...)` with optional `@par`, `@gpu`, `@local(...)`, `@local_init(...)`, and `@reduce(op: vars...)` annotations, `while`

## Control Flow

`if`/`elif`/`else`, `return`, `pass`, `sync`, `allocate(name, dims...)`

## Operators

`+`, `-`, `*`, `/`, `%`, `**`, `==`, `!=`, `<`, `>`, `<=`, `>=`, `and`, `or`, `not`, `+=`, `-=`, `*=`, `/=`

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

`dot`, `sum`, `product`, `minval`, `maxval`, `abs`, `sqrt`, `sin`, `cos`, `tan`, `exp`, `log`, `matmul`, `transpose`, `reshape`, `zeros`, `ones`, `linspace`, `arange`, `this_image`, `num_images`, `co_sum`, `co_min`, `co_max`, `co_broadcast`, `co_reduce`, `h5write`, `h5read`

## Standard Library

### `support.linalg`

Mimics `numpy.linalg`. Current LAPACK-backed helpers:

- `qr(a, q, r)` -- reduced QR with caller-provided outputs
- `solve(a, b, x)` -- square `A x = b` systems with a vector right-hand side
- `svd(a, u, s, vt)` -- reduced SVD with caller-provided outputs
- `eig(a, wr, wi, vr)` -- eigenvalues (`wr`/`wi` real and imaginary parts) and right eigenvectors of a real general matrix; eigenvector columns follow LAPACK `dgeev` packed layout

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

Top-level `import some_library`, `import support.linalg`, `import ./local_helper`, `import ../examples/linear_algebra`

Bare imports are resolved relative to the importing file first, then from the repository root. Path-style imports that start with `./` or `../` stay anchored to the importing file. This makes it possible to keep light standard-library modules under `support/` while also importing nearby example or helper files explicitly. Each source file is expanded at most once, so repeated or transitive imports of the same file do not redefine its contents.

## Process Control

`exit(code)` — statement-only builtin. Terminates the program immediately with the given integer exit code. Maps to Fortran `stop code`. Use `exit(0)` for success and `exit(1)` (or any non-zero value) for failure.

## HDF5 I/O

`h5write` and `h5read` are statement-only builtins backed by the
[h5fortran](https://github.com/geospace-code/h5fortran) high-level interface.

| Function | Signature | Description |
|---|---|---|
| `h5write(filename, dataset_name, value)` | 3 args | Open `filename`, write `value` as dataset `dataset_name`, close. |
| `h5read(filename, dataset_name, value)` | 3 args | Open `filename`, read dataset `dataset_name` into `value`, close. |

`value` may be a scalar or a 1D-7D array of any type that h5fortran supports
(`int`, `float`, ...). For arrays, `h5read`'s destination must already be
allocated to match the on-disk shape -- use `allocate(name, dims...)` to size
deferred-shape arrays before reading. Each call is self-contained (open ->
operate -> close), so multiple datasets can be added to the same `.h5` file by
calling the builtin repeatedly with the same filename.

See *examples/hdf5_io.py* for a round-trip demo covering scalars and 1D/2D/3D
arrays in the same file.

## Plotting

All plot functions are statement-only builtins backed by `pyplot-fortran`. They write a PNG to disk and require `python3` with `matplotlib` installed at runtime.

| Function | Arg counts | Description |
|---|---|---|
| `plot(x, y, file [, title [, xlabel, ylabel]])` | 3, 4, 6 | Line plot of y vs x |
| `histogram(x, file [, title [, xlabel, ylabel [, bins]]])` | 2, 3, 5, 6 | Histogram; default bins = 10 |
| `scatter(x, y, file [, title [, xlabel, ylabel]])` | 3, 4, 6 | Scatter plot (markers, no line) |
| `imshow(z, file [, title])` | 2, 3 | Heatmap of a 2-D float array |
| `contour(x, y, z, file [, title [, xlabel, ylabel]])` | 4, 5, 7 | Contour lines with colorbar |
| `contourf(x, y, z, file [, title [, xlabel, ylabel]])` | 4, 5, 7 | Filled contour regions with colorbar |

`contour` and `contourf` require `use_numpy=.true.` internally and expect `z` to have shape `(size(x), size(y))`.

## Notes

For a single-image local sanity check when using coarrays, plain `gfortran -fcoarray=single` is also sufficient.

See [DETAILS.md](DETAILS.md) for a full explanation of how the transpiler works.

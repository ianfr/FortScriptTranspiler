# Language Reference

## Loops

`for i in range(...)` with optional `@par`, `@gpu`, `@local(...)`, `@local_init(...)`, and `@reduce(op: vars...)` annotations, `while`

`break` exits the innermost active `for` or `while` loop. It is only supported in ordinary loops. `break` is rejected inside `@par` and `@gpu` loops because those lower to `do concurrent` or GPU kernels.

## Control Flow

`if`/`elif`/`else`, `return`, `break`, `pass`, `sync`, `allocate(name, dims...)`

## Operators

`+`, `-`, `*`, `/`, `%`, `**`, `==`, `!=`, `<`, `>`, `<=`, `>=`, `and`, `or`, `not`, `+=`, `-=`, `*=`, `/=`

## F-Strings

F-strings interpolate expressions into string literals using `f"..."` syntax with `{expr}` placeholders:

```python
title: string = f"Results (p={PROB_FILL}, n={GRID_LEN})"
imshow(grid, "out.png", f"Grid at t={step}")
```

Each `{expr}` is formatted via Fortran `write(..., '(g0)')` into a 256-character temporary and concatenated with `//`. An optional `:.Nf` format specifier controls decimal places for floats, lowering to `'(f0.N)'`:

```python
print(f"pi = {x:.4f}")        # -> "pi = 3.1416"
print(f"step {i}, val={v:.2f}")
```

Nesting f-strings is not supported.

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

### `support.random`

NumPy-style random helpers for serial fills, deterministic parallel draws, and coarray image seeding:

- `seed(s)` sets the serial RNG seed from one integer
- `random_fill(x)` fills a 1D float array with uniform values in `[0, 1)`
- `uniform_fill(low, high, x)` fills a 1D float array with uniform values in `[low, high)`
- `normal_fill(x)` fills a 1D float array with standard normal values
- `pm_step(state)` advances a Park-Miller integer RNG state
- `par_uniform(base_seed, i)` returns a stateless uniform value for 1D parallel work
- `par_uniform_2d(base_seed, i, j)` returns a stateless uniform value for 2D parallel work
- `par_uniform_3d(base_seed, i, j, k)` returns a stateless uniform value for 3D parallel work
- `image_seed(base_seed)` derives a per-image seed from `this_image()`

Use `par_uniform*` helpers inside `@par` loops instead of serial RNG calls. `random_fill`, `uniform_fill`, and `seed` are statement-only operations backed by generated Fortran helper routines.

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

### `support.sparse`

Pure FortScript sparse helpers. The direct LU path is suitable for small
problems; `cg` scales to larger 3D systems where a direct factor would blow
up in fill-in:

- `csr_array(data, row_ind, col_ind)` builds a `CSRMatrix` from COO-style triplets
- `csr_to_csc(a)` converts a `CSRMatrix` into a `CSCMatrix`
- `factorized(a)` computes a partial-pivoted LU factorization and returns a `FactorizedResult`
- `solve(fac, b)`, `solve_dc(fac, b)` solve one right-hand side using that factorization
- `spmv_csr(a, x)` does a parallel (`@par`) sparse matvec `y = A x` for CSR storage
- `cg(a, b, tol, max_iter)` solves `A x = b` with Conjugate Gradient for SPD `A`; spmv/axpy/dot kernels run under `@par`
- `cg(a, b, tol, max_iter)` returns the current iterate early if its curvature or residual becomes `NaN` or zero during the iteration, avoiding a divide-by-zero or `NaN` step-length update

`CSRMatrix` and `CSCMatrix` expose:
- `data` -- nonzero values
- `indices` -- column indices for CSR, row indices for CSC
- `indptr` -- row or column pointer offsets
- `num_rows`, `num_cols` -- matrix shape

`FactorizedResult` exposes:
- `L` -- unit-lower triangular factor stored as `CSCMatrix`
- `U` -- upper triangular factor stored as `CSCMatrix`
- `perm` -- row permutation from partial pivoting

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

For visualization tools such as ParaView, these builtins only create the raw
datasets. Grid-aware metadata can be generated with the XDMF helpers below.

## XDMF Output

`xdmf_add`, `xdmf_add_xyz`, and `xdmf_write` are statement-only builtins for
building a ParaView-readable XDMF sidecar alongside an HDF5 file.

| Function | Signature | Description |
|---|---|---|
| `xdmf_add(xml_str, field_name, field_array)` | 3 args | Append a node-centered scalar `Attribute` entry for rank-3 `field_array`, referencing dataset `/<field_name>` in the HDF5 file. |
| `xdmf_add_xyz(xml_str, x, y, z)` | 4 args | Append the `Topology` and `Geometry` entries for a 3D rectilinear grid, referencing datasets `/x`, `/y`, and `/z`. |
| `xdmf_write(xdmf_filename, h5_filename, xml_str)` | 3 args | Wrap the accumulated XML fragment and write the final `.xdmf` file, using `h5_filename` in all HDF dataset references. |

`xml_str` is updated in place and may be built up through repeated calls. The
current helper path targets ParaView-style 3D rectilinear grids with node
fields. `xdmf_add` currently supports rank-3 integer and float arrays, and
`xdmf_add_xyz` currently supports rank-1 integer and float coordinate arrays.

See *examples/hdf5_io_paraview.py* for a complete workflow that writes both the
`.h5` data file and the matching `.xdmf` sidecar from FortScript.

## Plotting

All plot functions are statement-only builtins backed by `pyplot-fortran`. They write a PNG to disk and require `python3` with `matplotlib` installed at runtime.

| Function | Arg counts | Description |
|---|---|---|
| `plot(x, y, file [, title [, xlabel, ylabel]])` | 3, 4, 6 | Line plot of y vs x |
| `histogram(x, file [, title [, xlabel, ylabel [, bins]]])` | 2, 3, 5, 6 | Histogram; default bins = 10 |
| `scatter(x, y, file [, title [, xlabel, ylabel]])` | 3, 4, 6 | Scatter plot (markers, no line) |
| `imshow(z, file [, title [, xlabel, ylabel]])` | 2, 3, 5 | Heatmap of a 2-D float array |
| `contour(x, y, z, file [, title [, xlabel, ylabel]])` | 4, 5, 7 | Contour lines with colorbar |
| `contourf(x, y, z, file [, title [, xlabel, ylabel]])` | 4, 5, 7 | Filled contour regions with colorbar |

`contour` and `contourf` require `use_numpy=.true.` internally and expect `z` to have shape `(size(x), size(y))`.

## Notes

For a single-image local sanity check when using coarrays, plain `gfortran -fcoarray=single` is also sufficient.

See [DETAILS.md](DETAILS.md) for a full explanation of how the transpiler works.

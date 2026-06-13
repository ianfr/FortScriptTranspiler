# Language Reference

## Loops

`for i in range(...)` with optional `@par`, `@omp`, `@gpu`, `@local(...)`, `@local_init(...)`, and `@reduce(op: vars...)` annotations, `while`

`@par` lowers the loop to Fortran `do concurrent`. `@omp` is a drop-in replacement that lowers to an OpenMP `parallel do` instead, which runs on CPU threads under gfortran `-fopenmp` and parallelizes by construction without dependence analysis. Use `@omp` for loops that GCC `do concurrent` autopar cannot thread, such as neighbor-gather stencils whose indirect reads are not affine. Both honor `@local`, `@local_init`, and `@reduce`: under `@omp` these map to OpenMP `private`, `firstprivate`, and `reduction`. For both, every scalar assigned in the loop body is made iteration-local automatically (do concurrent `local`/`local_init`, or OpenMP `private`/`firstprivate`), so the loops carry no shared scalar state. Thread count for `@omp` loops is set at run time with `OMP_NUM_THREADS`.

Because OpenMP gives no language-level diagnostic for a loop-carried dependence, the transpiler runs a safety check on `@omp` loops and rejects two patterns as errors: a scalar read before it is assigned in an iteration (an undeclared reduction or sequential dependence that auto-`firstprivate` would silently hide), and an array written at one index and read at a different cross-iteration index (a stencil reading its own output). To pass, declare the intent: `@reduce(op: var)` for a reduction, `@local_init(var)` for an intended carry-in, or restructure so the loop is genuinely independent.

`break` exits the innermost active `for` or `while` loop. It is only supported in ordinary loops. `break` is rejected inside `@par`, `@omp`, and `@gpu` loops because those lower to `do concurrent`, an OpenMP worksharing loop, or GPU kernels.

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

`append(arr, val)` grows an ordinary 1D deferred-shape array by one element:

```python
values: array[float, :]
append(values, 1.0)
append(values, 2.0)
```

The target must be a bare local or global array variable. If the array is not allocated yet, `append` allocates it with length 1. Function parameters and coarrays are not supported by `append`.

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

`dot`, `sum`, `product`, `minval`, `maxval`, `abs`, `sqrt`, `sin`, `cos`, `tan`, `exp`, `log`, `matmul`, `transpose`, `reshape`, `zeros`, `ones`, `linspace`, `arange`, `append`, `this_image`, `num_images`, `co_sum`, `co_min`, `co_max`, `co_broadcast`, `co_reduce`, `h5write`, `h5read`

## Standard Library

### `support.linalg`

Mimics `numpy.linalg`. Current LAPACK-backed helpers:

- `qr(a, q, r)` -- reduced QR with caller-provided outputs
- `solve(a, b, x)` -- square `A x = b` systems with a vector right-hand side
- `svd(a, u, s, vt)` -- reduced SVD with caller-provided outputs
- `eig(a, wr, wi, vr)` -- eigenvalues (`wr`/`wi` real and imaginary parts) and right eigenvectors of a real general matrix; eigenvector columns follow LAPACK `dgeev` packed layout

These helpers lower to generated LAPACK wrappers and are statement-only today, so the caller preallocates the output arrays before calling them. The default `FFLAGS` from `env-setup.sh` already include `-llapack -lblas`.

### `support.random`

Random number generation is backed by the [prand](https://github.com/cheng-zhao/prand)
parallel RNG C library, wrapped in the hand-written Fortran module
`support/prand_mod.f90`. Importing `support.random` makes the transpiler emit
`use prand_mod`; the build links the prand static library alongside it.

Serial helpers (single-stream generator):

- `seed(s)` reseeds the serial generator from one integer
- `random_fill(x)` fills a 1D float array with uniform values in `[0, 1)`
- `uniform_fill(low, high, x)` fills a 1D float array with uniform values in `[low, high)`
- `normal_fill(x)` fills a 1D float array with standard normal values (Box-Muller)
- `prand_uniform()` returns one uniform value in `[0, 1)` from the serial generator

Parallel helpers (one prand stream per OpenMP thread):

- `prand_seed_parallel(s)` initializes a multi-stream generator with one stream
  per OpenMP thread. Call once before an `@omp` loop that draws random numbers.
- `prand_uniform_thread()` returns one uniform value in `[0, 1)` from the calling
  thread's stream. Safe inside `@omp` loops.

Because the generator is stateful, random draws cannot be used inside a `@par`
(`do concurrent`) loop, which requires pure callees. For parallel draws use an
`@omp` loop with `prand_seed_parallel` + `prand_uniform_thread`. The per-thread
stream mapping means the parallel draw order depends on the thread count, so
`@omp` draws are not bit-reproducible across different thread counts.

For coarray (SPMD) programs each image is a separate process with its own
generator: call `seed(...)` on each image (identically for a shared global
sequence, or `seed(base + this_image() * k)` for independent per-image streams)
and draw with `prand_uniform()`.

`seed`, `random_fill`, `uniform_fill`, and `prand_seed_parallel` are statement-only.
`prand_uniform` and `prand_uniform_thread` are value-returning and are used in
expressions.

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
- `bicgstab(a, b, tol, max_iter)` solves `A x = b` with stabilized biconjugate gradient on general nonsymmetric `A`; spmv/axpy/dot kernels run under `@par` and the iteration returns the current iterate early on numerical breakdown
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

### `support.geom_stl`

3D triangle mesh utilities. `STLMesh` stores the triangle attributes as parallel arrays (twelve scalar arrays plus a precomputed bounding box) so the Fortran reader can fill them directly.

- `geom_stl_read_ascii(filename, mesh)` reads an ASCII STL file into `mesh`. Statement-only stub backed by the hand-written Fortran module `support/geom_stl_read.f90`.
- `geom_stl_read_binary(filename, mesh)` reads a binary STL file into `mesh`. Statement-only stub backed by the same Fortran module.
- `geom_stl_compute_bounds(mesh)` fills `mesh.min_bound`, `mesh.max_bound`, `mesh.center`.
- `geom_stl_translate(mesh, tx, ty, tz)` translates every vertex in place.
- `geom_stl_scale(mesh, s)` scales every vertex uniformly about the origin and recomputes bounds.
- `geom_stl_rotate(mesh, angle, ax, ay, az)` rotates vertices and normals about a unit axis using Rodrigues' formula.
- `geom_stl_point_tri_dist2(px, py, pz, ax, ..., cz)` returns the squared distance from a point to a single triangle.
- `geom_stl_ray_tri_hit(ox, oy, oz, dx, dy, dz, ax, ..., cz)` Moeller-Trumbore ray-triangle intersection test.
- `geom_stl_ray_count(mesh, ox, oy, oz, dx, dy, dz)` counts ray-triangle intersections across the mesh.
- `geom_stl_inscribed(mesh, qx, qy, qz)` returns `True` when the query point is inside a closed manifold mesh (ray cast along +X).
- `geom_stl_build_bins(mesh, nbin, bins)` populates an `STLBins` triangle bin grid (uniform 3D voxel structure over the STL bounding box). Each bin stores the list of triangle indices whose AABB intersects it as CSR-style `offsets`/`tri_ids` arrays. Also fills per-triangle AABB arrays (`tri_xmin`, ..., `tri_zmax`) used as a ray-prefilter. Use directly when reusing one bin grid across several SDF passes; `geom_stl_sdf_uniform` builds its own grid internally.
- `geom_stl_sdf_uniform(mesh, x_coords, y_coords, z_coords, sdf)` signed distance field on a rectilinear grid (positive outside, negative inside). The destination uses z-major storage (`sdf[k_z, j_y, i_x]`) so it can feed `geom_cartesian_refine_to_sdf` and `geom_cartesian_sample_sdf` directly. Builds an internal `STLBins` and samples every grid node with `geom_stl_sdf_point`. The outer loops run under `@par`.
- `geom_stl_sdf_point(mesh, bins, px, py, pz) -> float` signed distance at one point against a prebuilt `STLBins`. Walks bin shells outward for the nearest-triangle distance, then counts off-axis ray crossings for the inside/outside sign (negative inside). Pure, so it can be called inside `@par` loops. Build `bins` once with `geom_stl_build_bins` and reuse it for every query; this is the building block for sampling an SDF directly at arbitrary points (for example FVM cell centers) without an intermediate grid.
- `geom_stl_sdf_nbin(n_tri) -> int` picks the bin-grid resolution `geom_stl_sdf_uniform` uses internally; exposed so callers building their own `STLBins` for direct point sampling can match it.
- `geom_stl_sdf_write_hdf5(sdf, x_coords, y_coords, z_coords, filename)` writes the SDF and its axes as HDF5 datasets ready for pairing with the `xdmf_*` builtins.

Vector quantities are written as `array[float, 3]` (FortScript has no dedicated `vector3` type today). Two 3-vector example fields on `STLMesh`: `min_bound`, `max_bound`.

### `support.geom_cartesian`

3D cartesian cell-list mesh with struct-parameterized field sets. The user defines a "field set" struct whose members name the per-cell quantities and writes `mesh: CartesianMesh[FieldSet]`. The transpiler monomorphizes one Fortran derived type per instantiation that extends the base `CartesianMesh` and adds one allocatable per FieldSet field:

- `float` field -> rank-1 allocatable `real(8) :: <name>(:)`
- `array[float, 3]` field -> rank-2 allocatable `real(8) :: <name>(:,:)` with indexes `(cell, component)`
- Other field types are skipped with a comment.

Compiler-lowered built-ins handle construction and topology mutation:

- `geom_cartesian_uniform(mesh, dim_min, dim_max, spacing)` assigns the metadata fields, allocates the cell-list geometry and neighbor arrays, then `allocate`s each per-field array sized to `mesh.cell_capacity`. The compiler reads the type-parameter struct to know which arrays to allocate.
- `geom_cartesian_refine_cell(mesh, cell_id)` refines one active leaf cell into eight children, grows storage when needed, inherits FieldSet values into the children, updates `leaf_ids`, and rebuilds face neighbors via `geom_cartesian_rebuild_neighbors`.
- `geom_cartesian_refine_to_sdf(mesh, sdf, tol, max_level)` repeatedly refines active leaves whose center has interpolated `abs(sdf) <= tol` until they reach `max_level`. The SDF grid must span the mesh domain and uses z, y, x storage order in FortScript source as `sdf[k, j, i]`. A 2:1 balance cascade runs after the surface refinement converges.
- `geom_cartesian_refine_band(mesh, sdf, tol, max_level)` is the batched, snappyHexMesh-castellation-style band refinement. `sdf` is a per-cell scalar field (cell-id indexed, for example `mesh.sdf` filled by `geom_cartesian_sample_sdf`). Each pass marks every leaf below `max_level` with `abs(sdf) <= tol`, propagates 2:1 balance over the marked set, splits the whole batch at once, then recompacts `leaf_ids` and rebuilds the neighbor table once. Passes repeat until nothing is marked. This is the fast replacement for refining one cell at a time: cost is `O(L * N * tree_depth)` instead of `O(R * N^2)`. Resample `sdf` between calls (passing `lev + 1` as `max_level`) to tighten the band level by level.
- `geom_cartesian_coarsen_cell(mesh, cell_id)` coarsens a parent whose eight children are active leaves, averages FieldSet values back into the parent, updates `leaf_ids`, and rebuilds face neighbors via `geom_cartesian_rebuild_neighbors`. Storage is kept allocated for later reuse.

Small helpers operate on metadata only and need no FieldSet introspection:

- `geom_cartesian_centers(mesh, cx, cy, cz)` fills caller-provided rank-1 arrays with the cell-center coordinates.
- `geom_cartesian_leaf_corners(mesh, points, connectivity)` fills the eight corner vertices and the hex connectivity of every active leaf in VTK_HEXAHEDRON node order, ready to hand to `xdmf_add_unstructured` for ParaView export. Caller must allocate `points` with Fortran shape `(3, 8 * num_leaves)` and `connectivity` with Fortran shape `(8, num_leaves)`, so the bytes land in HDF5 row-major order. Corners are duplicated per cell so that refinement-induced hanging nodes do not need to be reconciled.
- `geom_cartesian_leaf_field(mesh, src, dst)` compacts a cell-capacity-sized scalar field down to one entry per active leaf, in `leaf_ids` order. Caller must allocate `dst` to length `num_leaves`. Pair with `geom_cartesian_leaf_corners` and `xdmf_add_cell` to export a leaf-centered scalar.
- `geom_cartesian_locate(mesh, x, y, z)` returns the 0-based id of the active leaf cell containing a world-space point, or `-1` when the point is outside the domain. Implemented as a plain FortScript function that picks the root cell from the uniform grid spacing and then descends through `mesh.children` using the same Morton-style octant ordering as `geom_cartesian_refine_cell`.
- `geom_cartesian_find_imbalance(mesh)` returns the 0-based id of a coarse leaf whose level is more than one below the level of an adjacent leaf, or `-1` when the mesh already satisfies the 2:1 balance rule. Used by the lowered refine helpers to drive the balance cascade and available to user code that needs to re-balance after custom mutations.
- `geom_cartesian_rebuild_neighbors(mesh)` rebuilds the per-face neighbor table for every active leaf by point-location probing rather than an all-pairs overlap scan. For each leaf face it locates the four sub-quadrant points just outside the face: a coarser or equal neighbor fills all four slots with the same id, up to four finer neighbors fill one slot each, and a probe outside the domain stores `-1`. Cost is `O(num_leaves * tree_depth)`. The lowered refine and coarsen helpers call it after they change topology; user code can call it after custom mutations.
- `geom_cartesian_face_neighbor_kind(mesh, c, face)` classifies a face as same-level neighbor or boundary in the current uniform implementation.
- `geom_cartesian_face_center(mesh, c, face, fc)` fills `fc` with the world-space face center.
- `geom_cartesian_face_normal(face, n)` fills `n` with the outward unit normal.
- `geom_cartesian_sample_sdf(mesh, x_sdf, y_sdf, z_sdf, sdf_grid, nx_sdf, ny_sdf, nz_sdf, sdf_out)` samples a rectilinear SDF grid at every active leaf center using trilinear interpolation. The grid must use z-major storage (`sdf_grid[k_z, j_y, i_x]`) and uniformly spaced coordinate arrays, matching the convention of `geom_cartesian_refine_to_sdf`. `sdf_out` must be allocated to `mesh.cell_capacity` before calling. For immersed-body FVM, prefer `fvc_sample_sdf_from_stl` (in `support.geom_cartesian_fvm`), which samples the exact STL distance at each leaf center and avoids both the intermediate grid and the interpolation smoothing.
- `fvc_sample_sdf_from_stl(mesh, stl, bins, sdf_out)` (in `support.geom_cartesian_fvm`) fills `sdf_out` (cell-id indexed) with the exact STL signed distance at every active leaf center via `geom_stl_sdf_point`. Build `bins` once with `geom_stl_build_bins` (sized by `geom_stl_sdf_nbin`); the bins depend only on the STL, so the same `bins` serve every refinement pass. The leaf loop runs under `@par`.

The current mesh builds a uniform root cell list and supports leaf refinement, coarsening, and SDF-driven surface refinement. See [GEOM_AMR_PLAN.md](./GEOM_AMR_PLAN.md) for the remaining adaptive-refinement phases.

All field reads and writes use direct struct access. Because each field is a real Fortran derived-type component, the standard FortScript assignment and indexing rules apply:

```python
mesh.temperature = 300.0             # broadcast scalar to every cell
mesh.pressure[:] = 101325.0          # fill via slice assignment
mesh.temperature[c] = 350.0          # single-cell write
val = mesh.temperature[c]            # single-cell read
mesh.velocity[c, 0] = 1.5            # vector-field component
```

The metadata fields (`nx`, `ny`, `nz`, `num_cells`, `num_leaves`, `cell_capacity`, `leaf_ids`, `level`, `center`, `dx`, `volume`, `face_area`, `parent`, `children`, `is_leaf`, `neighbor`, `dom_min`, `dom_max`, `spacing`) are inherited from the base `CartesianMesh` via Fortran type extension. See [examples/support_geom_cartesian_demo.py](./examples/support_geom_cartesian_demo.py).

#### CartesianMesh indexing

A `CartesianMesh[FieldSet]` covers a 3D box `[dom_min, dom_max]` with a uniform root grid of `(nx, ny, nz)` cells of side `spacing`. Cells are stored in a flat 0-based id space with x as the fastest-varying coordinate:

```text
c = (k * ny + j) * nx + i
```

**Scalar fields.** Each scalar field is a 1D array indexed by cell id:

```python
val = mesh.temperature[c]
mesh.pressure[:] = 101325.0             # fill the whole field
mesh.temperature = 300.0                # equivalent shorthand
```

**Vector fields** (`array[float, 3]` in the field set) are rank-2: `(cell, comp)`, where `comp = 0, 1, 2` selects x/y/z.

```python
mesh.velocity[c, 0] = vx
mesh.velocity[:, :] = 0.0
```

**Cell metadata.** Geometry and connectivity are stored alongside the fields:

```python
vol: float = mesh.volume[c]
area: float = mesh.face_area[c, 0]
xc: float = mesh.center[c, 0]
nbr: int = mesh.neighbor[c, 1, 0]
```

**Cell centers.** Cell id `c = (k * ny + j) * nx + i` has world-space center

```text
cx = mesh.dom_min[0] + (i + 0.5) * mesh.spacing
cy = mesh.dom_min[1] + (j + 0.5) * mesh.spacing
cz = mesh.dom_min[2] + (k + 0.5) * mesh.spacing
```

Multi-level adaptive refinement is available through the SDF refinement helpers. `geom_cartesian_refine_cell` and `geom_cartesian_refine_to_sdf` enforce a 2:1 balance cascade after the user-requested refinement: any neighbor whose level would otherwise sit more than one below a refined leaf is itself refined, and the cascade iterates until every leaf satisfies the rule. `geom_cartesian_refine_band` enforces the same 2:1 rule in batches: it propagates balance over the marked set before splitting, so the whole pass refines and rebuilds neighbors once instead of per cell.

### `support.geom_cartesian_fvm`

Finite-volume operators over `CartesianMesh` cell lists. The module follows an OpenFOAM-style separation: `fvc_*` routines compute explicit fields directly, and `fvm_*` routines add matrix and right-hand-side contributions to an equation builder.

`FVMEquation` exposes:

- `n_rows` - allocated cell-id row capacity
- `diag` - diagonal coefficient per cell id
- `offdiag` - face-neighbor coefficients indexed `(cell, face, sub)`
- `rhs` - right-hand side per cell id

Construction and reset:

- `fvm_equation_init(eq, mesh)` allocates `diag`, `offdiag`, and `rhs` over `mesh.cell_capacity`. This call is compiler-lowered because FortScript allocation syntax only accepts bare variable names.
- `fvm_equation_zero(eq)` resets all coefficients to zero without reallocating.

Explicit `fvc_*` operators:

- `fvc_ddt(mesh, field_old, field_new, dt, ddt_out)` fills `(field_new - field_old) / dt`.
- `fvc_d2dt2(mesh, field_oldest, field_old, field_new, dt, d2_out)` fills a three-level second time derivative.
- `fvc_interpolate(mesh, field, face_field_out)` linearly interpolates a scalar field to `(cell, face)` storage.
- `fvc_div_flux(mesh, phi_face, div_out)` computes divergence of scalar face fluxes.
- `fvc_face_slot_area(mesh, c, f, s)` returns the area represented by one face-neighbor slot. Split coarse-to-fine faces use one quarter of the face area per slot; same-level, coarser-neighbor, and boundary faces use slot 0 for the full area.
- `fvc_div(mesh, vector_field, div_out)` computes divergence of a cell-centered vector field.
- `fvc_grad(mesh, field, grad_out)` computes the cell-centered gradient of a scalar field.
- `fvc_laplacian(mesh, gamma_face, field, lap_out)` computes an explicit two-point scalar Laplacian.

Implicit `fvm_*` assembly helpers:

- `fvm_ddt(eq, mesh, field_old, dt)` adds the implicit first time derivative.
- `fvm_d2dt2(eq, mesh, field_oldest, field_old, dt)` adds an implicit three-level second time derivative.
- `fvm_div(eq, mesh, phi_face)` adds an upwind implicit convection stencil.
- `fvm_div_dirichlet(eq, mesh, phi_face, face_sel, value)` adds known-value inflow contributions for an upwind convection boundary.
- `fvm_laplacian(eq, mesh, gamma_face)` adds a two-point diffusion stencil using mesh face-neighbor slots and their represented areas.
- `fvm_source_lhs(eq, mesh, coeff_field)` adds an implicit source coefficient to the diagonal.
- `fvm_source(eq, mesh, source_field)` adds an explicit volumetric source to the RHS.
- `fvm_add_to_rhs(eq, mesh, scale, field)` adds a scaled explicit field contribution to the RHS.
- `fvm_dirichlet(eq, mesh, gamma_face, face_sel, value)` applies a Dirichlet boundary condition on every external face whose face index matches `face_sel` (0..5, or -1 for every external face). It augments the diagonal with `gamma * area / (dx/2)` and the right-hand side with the same coefficient times `value`.
- `fvm_neumann(eq, mesh, face_sel, flux)` applies a Neumann (specified-flux) boundary condition on the selected external faces. `flux` is the outward-positive flux density and contributes purely to the right-hand side.
- `fvm_to_csr(eq, mesh)` converts the active cell-id equation rows to `CSRMatrix` storage from `support.sparse`.
- `fvm_solve_cg(eq, mesh, field_out, tol, max_iter)` converts to CSR and solves with `support.sparse.cg` for SPD systems (for example pure diffusion with Dirichlet conditions).
- `fvm_solve_bicgstab(eq, mesh, field_out, tol, max_iter)` converts to CSR and solves with `support.sparse.bicgstab` for nonsymmetric systems such as those containing the upwind convection stencil.
- `fvm_solve_diag(eq, mesh, field_out)` applies a diagonal-only solve for equations without off-diagonal terms.

#### Face flux convention

All new face-flux arrays use the outward convention: `phi[c, f] > 0` means net flux leaving cell `c` through face `f`. Even-indexed faces (0, 2, 4 = -x, -y, -z) have outward normal pointing in the negative axis direction, so a positive x-velocity at face 0 gives `phi[c, 0] < 0` (inflow). `fvc_div_flux` sums all six aggregate face fluxes; the result is zero for incompressible uniform flow. On adaptive meshes, operators that need neighbor-specific contributions split a coarse-to-fine aggregate face flux over the four subface slots using `fvc_face_slot_area`.

#### BDIM helpers

- `fvc_bdim_mu0(d, eps)` returns the BDIM zeroth moment for a cell at signed distance `d` from the body surface.
- `fvc_bdim_mu1(d, eps)` returns the BDIM first moment (interface thickness kernel).
- `fvc_bdim_weights(mesh, sdf_cell, eps, mu0_out, mu1_out, solid_mask_out)` fills `mu0`, `mu1`, and `solid = 1 - mu0` for every active leaf.
- `fvc_sdf_normal(mesh, sdf_cell, normal_out)` fills the normalized SDF gradient at every active leaf center (points solid to fluid).
- `fvc_normal_derivative_vector(mesh, vector_field, normal, dn_out)` computes `grad(u_k) dot normal` for each component `k`.
- `fvc_bdim_apply_static_body(mesh, u_fluid, normal, mu0, mu1, u_out)` blends the fluid velocity toward zero using the BDIM cosine kernel for a static no-slip body. Safe to call with `u_out` aliasing `u_fluid`.

#### Vector and flux helpers

- `fvc_vector_mag(mesh, vector_field, mag_out)` fills `|u|` at every active leaf.
- `fvc_yPlus(mesh, velocity, normal, mu0, nu, yPlus_out)` fills the dimensionless wall distance at every active leaf. For cells in the BDIM transition band (0 < mu0 < 1), computes `|u_tangential| * |sdf| / nu` where `u_tangential` is the velocity component perpendicular to the SDF surface normal. Returns 0 for solid and deep-fluid cells.
- `fvc_flux_from_velocity(mesh, velocity, phi_face_out)` computes `phi[c,f] = u_face dot n_f * A_f` using linear face interpolation and subface accumulation on adaptive faces (outward convention).
- `fvc_interpolate_vector(mesh, vector_field, face_vector_out)` linearly interpolates a cell-centered vector to `(cell, face, component)` storage.
- `fvc_grad_component(mesh, vector_field, component, grad_out)` computes the cell-centered gradient of one vector component.
- `fvc_vorticity(mesh, velocity, vort_out)` computes the cell-centered curl of a velocity field into `(cell, component)` storage.

#### Momentum assembly and relaxation

- `fvm_momentum_component(eq, mesh, u_old_comp, phi_face, nu_face, dt)` adds the transient, upwind convection, and Laplacian diffusion terms for one velocity component.
- `fvm_bdim_static_body_penalty(eq, mesh, mu0, penalty, body_value)` adds `penalty * (1 - mu0) * volume` to the diagonal to drive solid cells toward `body_value`.
- `fvm_under_relax(eq, mesh, field_old, alpha)` applies matrix under-relaxation: scales the diagonal by `1/alpha` and adds the implicit correction to the RHS.
- `fvc_under_relax_scalar(mesh, old_field, new_field, alpha)` blends a scalar field explicitly.
- `fvc_under_relax_vector(mesh, old_field, new_field, alpha)` blends a vector field explicitly.

#### Pressure-velocity coupling

- `fvc_inverse_diag(mesh, eq, inv_diag_out)` computes `1/A` from the momentum equation diagonal.
- `fvc_HbyA_component(mesh, eq, field, invA, hbyA_out)` computes `H(u)/A` for one velocity component.
- `fvc_flux_from_hbyA(mesh, hbyA, phiHbyA_out)` computes the face flux from `HbyA` (same convention as `fvc_flux_from_velocity`).
- `fvm_pressure_laplacian(eq, mesh, invA_face)` assembles `div(invA * grad(p))` by wrapping `fvm_laplacian`.
- `fvm_pressure_laplacian_invA(eq, mesh, invA)` assembles the pressure Laplacian from cell `invA` values with slot-local interpolation on adaptive faces.
- `fvm_pressure_dirichlet_invA(eq, mesh, invA, face_sel, value)` applies a pressure Dirichlet condition using cell `invA` at selected external faces.
- `fvc_pressure_flux_correction(mesh, pressure, invA_face, phiHbyA, phi_out)` corrects `phi = phiHbyA - invA_face * area * (p[nb] - p[c]) / d_centers` over all interior face-neighbor slots.
- `fvc_pressure_flux_correction_dirichlet(mesh, pressure, invA_face, phiHbyA, face_sel, value, phi_out)` applies the same interior correction and adds the matching pressure Dirichlet boundary flux on selected external faces.
- `fvc_pressure_flux_correction_dirichlet_invA(mesh, pressure, invA, phiHbyA, face_sel, value, phi_out)` applies the pressure flux correction with the same slot-local `invA` coefficients as `fvm_pressure_laplacian_invA`.
- `fvc_momentum_pressure_correct(mesh, hbyA, invA, pressure, velocity_out)` corrects `u = HbyA - invA * grad(p)`.

Cell-list sweeps in the module are parallelized in one of two ways. Element-wise kernels (those that only touch cell-`c` indexed arrays) iterate the dense cell-id space `range(mesh.cell_capacity)` under an `if mesh.is_leaf[c]` guard and are annotated `@par`; the direct cell-id write keeps the generated `do concurrent` affine so GCC autopar can thread it. Stencil kernels that read neighbor values through `mesh.neighbor` keep the compact `leaf_ids` iteration and are annotated `@omp`, because their indirect gather reads are not affine and only the OpenMP `parallel do` threads them under gfortran. A few BDIM setup routines and the solver copy-back loops remain serial.

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

`xdmf_add`, `xdmf_add_xyz`, `xdmf_add_unstructured`, `xdmf_add_cell`, and
`xdmf_write` are statement-only builtins for building a ParaView-readable
XDMF sidecar alongside an HDF5 file.

| Function | Signature | Description |
|---|---|---|
| `xdmf_add(xml_str, field_name, field_array)` | 3 args | Append a node-centered scalar `Attribute` entry for rank-3 `field_array`, referencing dataset `/<field_name>` in the HDF5 file. |
| `xdmf_add_xyz(xml_str, x, y, z)` | 4 args | Append the `Topology` and `Geometry` entries for a 3D rectilinear grid, referencing datasets `/x`, `/y`, and `/z`. |
| `xdmf_add_unstructured(xml_str, points, connectivity)` | 3 args | Append an unstructured `Hexahedron` `Topology` and `XYZ` `Geometry` entry, referencing datasets `/points` (Fortran shape `(3, N)`) and `/connectivity` (Fortran shape `(8, M)` with VTK hex node ordering). The reversed shape is intentional: Fortran column-major storage lines up with HDF5 row-major reads only when the inner dimension is the fast Fortran axis. |
| `xdmf_add_cell(xml_str, field_name, field_array)` | 3 args | Append a cell-centered scalar `Attribute` entry for rank-1 `field_array`, referencing dataset `/<field_name>` in the HDF5 file. |
| `xdmf_write(xdmf_filename, h5_filename, xml_str)` | 3 args | Wrap the accumulated XML fragment and write the final `.xdmf` file, using `h5_filename` in all HDF dataset references. |

`xml_str` is updated in place and may be built up through repeated calls. The
structured path (`xdmf_add_xyz` + `xdmf_add`) targets 3D rectilinear grids
with node-centered fields. The unstructured path
(`xdmf_add_unstructured` + `xdmf_add_cell`) targets hex meshes with
cell-centered fields, which is the natural fit for adaptively refined
`CartesianMesh` exports where leaf cells live at multiple levels.
`xdmf_add` and `xdmf_add_cell` currently support integer and float arrays of
the required rank; `xdmf_add_xyz` and `xdmf_add_unstructured` accept the same
element types for their coordinate and connectivity arrays.

See *examples/hdf5_io_paraview.py* for a structured rectilinear workflow,
*examples/support_fvm_heat_validation.py* for a uniform cell-centered export,
and *examples/support_geom_cartesian_amr_paraview.py* for an unstructured hex
export of an adaptively refined `CartesianMesh`.

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

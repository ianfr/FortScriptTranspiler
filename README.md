# FortScript Transpiler

A transpiler from FortScript (a Python-like numerical computing language) to modern parallel Fortran, written in [OCaml](https://ocaml.org/) using [Menhir](https://gitlab.inria.fr/fpottier/menhir) and [ocamllex](https://ocaml.org/manual/5.4/lexyacc.html).

**Goals**:
- Use a Python-like language to generate parallel, scalable, readable, high-performance scaffolding for Fortran programs, and
- Provide a fast numerical computing language in its own right for those uninterested in Fortran. 

**Parallelism**:
- Loop-level with [`do concurrent`](https://www.intel.com/content/www/us/en/docs/fortran-compiler/developer-guide-reference/2025-3/do-concurrent.html)
- SPMD (MPI-style) with [coarrays](https://www.intel.com/content/www/us/en/docs/fortran-compiler/developer-guide-reference/2025-3/coarrays-001.html)

**Inspired in part by**:
- the [mojo](modular.com/open-source/mojo) language
- the [transpyle](https://github.com/mbdevpl/transpyle) project
- the [pyccel](https://github.com/pyccel/pyccel) project
- the [pythran](https://pythran.readthedocs.io/en/latest/) project

See the [examples/](./examples) directory for FortScript examples to refer to (or to point LLMs to...) when writing programs.

See [LANGUAGE.md](./LANGUAGE.md) for more details about the FortScript language itself.

See [DETAILS.md](./DETAILS.md) for more info about how the transpiler works.

Percolation example from [percolation.py](./examples/percolation.py):
|  p=0.4 (No Percolation)  | p=0.61      (Percolation)       |
| ----------------------------------- | ----------------------------------- |
| ![p04](./media/percolation_clusters_p0-4.png) | ![p061](./media/percolation_clusters_p0-61.png) |

## Benchmarks

See [build-benchmarks.sh](./build-benchmarks.sh) for CPU-only benchmarks.

<img src="media/benchmark_chart.png" width="500" />

### Shallow Water Equations Benchmark

Adapted from [shallow-water](https://github.com/jostbr/shallow-water).
Uses a 16000x16000 grid.
Serial FortScript uses ~75% less memory than the NumPy baseline while being ~8x faster.
See [benchmarks/python/shallow_water.py](./benchmarks/python/shallow_water.py) for details.

### 3D Ising Glauber Benchmark

3D Ising model with heat-bath (Glauber) dynamics with ~134 million grid points. The coarray benchmark decomposes the lattice into z-slabs, exchanges ghost planes between neighboring images, and reduces observables across images.

Based on Herrmann & Bottcher, Computational Statistical Physics, 2021. See references in [benchmarks/python/ising_glauber.py](benchmarks/python/ising_glauber.py) for more details.

### Molecular Dynamics Benchmark

Molecular dynamics benchmark adapted from [pyccel-benchmarks](https://github.com/pyccel/pyccel-benchmarks/tree/main):

[benchmarks/python/md.py](./benchmarks/python/md.py) stays close to the original loop-heavy version, while
[benchmarks/python/md_numpy.py](./benchmarks/python/md_numpy.py) uses NumPy broadcasting and whole-array operations
for a more idiomatic Python comparison point. Number of particles increased to 200x of original `pyccel` benchmark to make the problem size large enough for parallelism.

## Features

- Simple, strongly typed Python-like syntax
- Fortran parallelism: `do concurrent` for loops; coarrays for MPI-style programming
- Imperative programming style:
    - Structs, not classes (nesting allowed)
    - No recursion
- NumPy-inspired array syntax:
    - array operations mapped to Fortran intrinsics
    - array slicing with slice assignment
    - `numpy.linalg` equivalents
- Support library that itself is partly written in FortScript (dense & sparse linear algebra, optimization)
- Fixed-size and dynamically sized arrays
- Basic whole-file imports with relative paths
- Leverages BLAS/LAPACK
- HDF5 file I/O
- Generates modern F2018-compliant Fortran
- Save-to-disk plotting

**Parallelism**:
- `@par` loop annotation generates `do concurrent` loops
    - Optional `@local(...)`, `@local_init(...)`, and `@reduce(op: vars...)` clauses lower to native Fortran 2018 `LOCAL` / `LOCAL_INIT` locality specifiers on `do concurrent`; reductions use a per-iteration array combined after the loop
    - Inner loop variables nested inside a `@par` body are automatically added to `LOCAL`
    - Transpiler marks functions inside `do concurrent` loops as `pure`
    - `@gpu` on top of `@par` extracts the loop to a separate `_gpu.f90` kernel for Linux `nvfortran` builds
    - **Note**: Not all loops marked with `@par` will be parallelized if the compiler deems it either:
        - Impossible due to a data dependency, or
        - Not worth the overhead due to array sizing.
- Coarray SPMD support with `*` type annotations, `{img}` remote access, `sync`, `allocate`
    - F2018 collective operations (`co_sum`, `co_min`, `co_max`, `co_broadcast`, `co_reduce`)
    - Combining `@par` with coarrays is allowed; Mimics the common MPI+OpenMP setup in HPC

## Quick Start

There are three methods for building and running the FortScript transpiler:
1. VS Code dev container,
2. Docker/Apptainer,
3. Local Linux install

**Option 1: (VS Code Dev Container)**

Make sure VS Code and [Docker](https://www.docker.com/) are installed, along with the
VS Code "Container Tools" extension pack.

Just open the FortScript repo in VS Code, and a prompt should appear to reopen in a container.

Once the container is connected, build the FortScript dependencies:
```bash
bash dependencies.sh
```

**Option 2: (Docker)**

Only [Docker](https://www.docker.com/) is required.

_Note: in HPC contexts, Apptainer is a reccomended as a Docker replacement._

From the .devcontainer folder:

```bash
docker build -t fortscript .
```

You can then mount a local folder to /home/ubuntu/work inside the container like so from the FortScript repo:

```bash
docker run --rm -it \
    --pid=host --ipc=host --cap-add=SYS_PTRACE --shm-size=8g \
    -v /SOME/LOCAL/FOLDER:/home/ubuntu/work -w /home/ubuntu/work \
    -v $PWD:/home/ubuntu/FortScript -w /home/ubuntu/FortScript \
    fortscript:latest
```

Once the container is connected, build the FortScript dependencies:
```bash
cd ~/FortScript
bash dependencies.sh
```

**Option 3: (Local Install)**

_NOTE: Local install is not reccomended, as testing and development are done with containers to avoid packaging inconsistencies on arm64. However, amd64 platforms should have less trouble._

A Debian-based Linux distribution is reccomended (but certainly not necessary).

The primary dependency issues revolve around using GCC **15.2** for its modern language features.
This forces MPICH-backed OpenCoarrays, since OpenMPI is no longer supported for GCC 15+ with OpenCoarrays.

See [dependencies.sh](./dependencies.sh) for an installation reference.

Automation of local installation is actively being investigated, potentially leveraging HPC package managers like spack.

**Run a FortScript example application:**

```bash
source env-setup.sh

 _build/default/bin/main.exe examples/heat_diffusion.py -o heat_diffusion.f90

gfortran $(echo $PFFLAGS) -o heat_diffusion heat_diffusion.f90

./heat_diffusion
```

**Build all examples:**
- `bash build-examples.sh`

**Build all benchmarks:**
- `bash build-benchmarks.sh`

**Build and run benchmarks (_long_ runtime)**
- `bash run-benchmarks.sh`

**Build and run tests**
- `bash build-tests.sh && bash run-tests.sh`

## Example

```python
struct Particle:
    x: float
    y: float
    mass: float

def step(n: int, 
         vx: array[float], 
         vy: array[float],
         particles: array[Particle], 
         dt: float
    ):
    @par # Parallel loop!
    for i in range(n):
        particles[i].x += vx[i]*dt
        particles[i].y += vy[i]*dt
```

## Language Reference

See [LANGUAGE.md](LANGUAGE.md) for the full language reference (types, builtins, array access, imports, operators, plotting, and standard library).

## Standard Library

FortScript ships light support modules under [`support/`](./support):

- [`support.linalg`](./support/linalg.py) for LAPACK-backed dense linear algebra
- [`support.optimize`](./support/optimize.py) for a pure-FortScript Nelder-Mead solver
- [`support.random`](./support/random.py) for serial and parallel random number generation
- [`support.sparse`](./support/sparse.py) for pure-FortScript:
    - CSR/CSC sparse matrix assembly, 
    - LU factorization and direct solves, 
    - parallel sparse matrix-vector multiplcation, 
    - and a `@par`-accelerated Conjugate Gradient iterative solver (`cg`) for SPD systems.

See [examples/support_linalg.py](./examples/support_linalg.py), [examples/support_optimize.py](examples/support_optimize.py), [examples/support_random.py](examples/support_random.py), and [examples/support_sparse.py](examples/support_sparse.py) for some support library usage examples.

## Parallelism: Parallel Loops

[`examples/parallel_bench.py`](./examples/parallel_bench.py) is an example of a program that `gfortran` deems 'worth it' to parallelize.

Compile with:
- `_build/default/bin/main.exe examples/parallel_bench.py -o parallel_bench.f90`
- `gfortran $(echo $PFFLAGS) -o parallel_bench parallel_bench.f90`

Observe the output from the `-ftree-parallelize-loops` & `-fopt-info-loop` flags:


>parallel_bench.f90:14:85: optimized: **parallelizing** inner loop 5

>parallel_bench.f90:46:107: optimized: **parallelizing** inner loop 1

>parallel_bench.f90:14:85: optimized: **parallelizing** inner loop 1

This tells us that the loop we marked with @par is parallelized successfully (line 14 in the generated code):
```python
@par
for i in range(n):
    y[i] = exp(-x[i] * x[i]) * cos(x[i] * 3.14159265358979)
```
```fortran
do concurrent (i = 0:n - 1)
    y(i + 1) = (exp(((-x(i + 1)) * x(i + 1))) * cos((x(i + 1) * 3.14159265358979)))
end do
```

But we also see another loop mentioned, at line 46. `gfortran` was able to parallelize `linspace` as well:
```python
x: array[float] = linspace(-5.0, 5.0, n)
```
```fortran
x = [(((-5.0d0) + (5.0d0 - (-5.0d0)) * dble(fortscript_i__) / dble(n - 1)), fortscript_i__ = 0, n - 1)]
```

FortScript also supports `do concurrent` clauses through stacked annotations above an `@par` loop:

```python
@par
@local(tmp)
@local_init(seed)
@reduce(add: total)
@reduce(max: peak)
for i in range(n):
    ...
```

which lowers to native Fortran 2018 `LOCAL` / `LOCAL_INIT` locality specifiers on `do concurrent`, with array-based reduction scaffolding after the loop. Inner loop variables nested inside the `@par` body are automatically added to `LOCAL`.

`@local(...)` and `@local_init(...)` currently support scalar variables. See [examples/do_concurrent_features.py](./examples/do_concurrent_features.py) for a complete example.

A note: you can use `support.random.par_uniform/par_uniform_2d/par_uniform_3d` for random variates inside `@par` loops. These helpers are stateless pure functions, so they are safe in generated `do concurrent` regions.

## Parallelism: GPU Acceleration (Experimental)

FortScript has experimental support for offloading `@par` loops into separate Fortran kernels for `nvfortran` using the `@gpu` decorator:

```python
@par
@gpu
for i in range(n):
    y[i] = gaussian_rbf(x[i])
```

Build:
- `fs_build_gpu examples/gpu_rbf_kernel.py`
- `./out/gpu_rbf_kernel`

Current restrictions (on top of the CPU `@par` ones):
- Array references inside `@gpu` loops are limited to rank-1 and rank-2 arrays

See [examples/gpu_rbf_kernel.py](./examples/gpu_rbf_kernel.py) and [env-setup.sh](./env-setup.sh).

## Parallelism: Coarrays

FortScript has support for MPI-style programming (Single Program Multiple Data, SPMD) that transpiles to Fortran coarrays:

```python
def main():
    me: int = this_image()
    shared: float* = 0.0

    if me == 0:
        shared = 42.0

    sync
    print(shared{0})
```

Notes:
- Deferred-shape coarrays must be allocated explicitly with `allocate(...)`.
- The compiler automatically inserts a final `sync all` at the end of `main()`.

Restrictions (some of which are from Fortran standards): 
- No coarray struct fields
- No coarray parameters
- No coarray return types
- No coarray operations inside `@par` loops

See [examples/coarray_multiple_codims.py](./examples/coarray_multiple_codims.py) for a 2D block-decomposed heat-diffusion example using a 2-codimension coarray image grid and `@par` for the local stencil sweep. The example snapshots the coarray tile into a plain local array, then runs a column-by-column stencil with an inner `@par` sweep over the contiguous dimension so the generated `do concurrent` kernel reads local data and writes each output cell exactly once.

### Collective operations

Coarray collectives operate in-place on coarray variables across all images:

```python
val: float* = 0.0
val = 1.0 * (me + 1)
sync
co_sum(val)        # Every image now sees the global sum.
co_min(val)        # Global minimum.
co_max(val)        # Global maximum.
co_broadcast(val, 0)  # Broadcast from image 0 to all.
co_reduce(val, my_add) # User-defined reduction (function must be pure).
```

Notes:
- Collective operations are statement-only (cannot be used in expressions).
- The argument must be a coarray variable (scalar or array). Array arguments are reduced element-wise.
- `co_broadcast` takes a 0-based source image index
- The operation function passed to `co_reduce` must be pure

See [examples/coarray_collective_operations.py](./examples/coarray_collective_operations.py) for more details.

### Compiling & running coarray programs

Transpilation is the same as always:
- `_build/default/bin/main.exe examples/coarray_hello.py -o coarray_hello.f90`

And compilation is the same too, except `caf` is used instead of `gfortran`:
- `caf $(echo $FFLAGS) -o coarray_hello coarray_hello.f90`

To run, instead of executing directly use `cafrun` to set the number of parallel images:
- `cafrun -np 4 ./coarray_hello`

## HDF5 I/O

FortScript has language builting for HDF5 I/O that call out to the
[h5fortran](https://github.com/geospace-code/h5fortran) high-level interface.
Each call opens the target file, writes/reads the named dataset, and closes
the file again, so multiple datasets can live in the same `.h5` file by reusing
the filename:

```python
# writing
h5write("data.h5", "/pi", 3.14159)                 # scalar
h5write("data.h5", "/x1d", linspace(0.0, 1.0, 5))  # 1D array
# reading
y2d: array[float, :, :]
allocate(y2d, 2, 3)                                # h5read needs storage to exist
h5read("data.h5", "/x2d", y2d)
```

Both builtins work for scalars and 1D-7D arrays of `int`/`float` (and the
other types h5fortran supports). For arrays, `h5read`'s destination must
already be allocated to the on-disk shape. See [examples/hdf5_io.py](./examples/hdf5_io.py) for a
read/write demo covering scalars and 1D/2D/3D arrays in a single file.

To view 3D structured-grid HDF5 data in [ParaView](https://www.paraview.org/) a small XDMF metadata file is needed.
FortScript provides a set of `xdmf*` functions for building that metadata.
See [examples/hdf5_io_paraview.py](./examples/hdf5_io_paraview.py) for an example.

## Future Work

- Geometry processing support module written mostly in FortScript
- Better parallel RNG with [SPRNG](https://www.cs.fsu.edu/~sprng/Version5.0/examples.html)
- Pull compilation commands into shell functions in [env-setup.sh](./env-setup.sh)
- HDF5 struct import/export 
- More `do concurrent` control
    - `shared(...)`
    - `default(none)`
    - Native `REDUCE` clause once gfortran parallelizes it (currently uses array-based workaround)
- Expand coarray support
    - Coarray subroutine parameters (but, coarray return values are not allowed by the standard)
    - Teams
- Add support for LLVM/[PRIF](https://flang.llvm.org/docs/ParallelMultiImageFortranRuntime.html)
- New `float32` type
- Expand bootstrapped numerical routines written in FortScript in the support library
    - More sparse linear algebra
    - More optimization routines
- Expand LAPACK/BLAS wrappers closely matching `numpy.linalg`
- GPU follow-up:
    - Test more kernels beyond the current elementwise example set
    - Explore coarray + GPU interoperability more thoroughly (Test calling GPU `do concurrent` loops from coarray program (2 images))
    - Improve Linux/NVHPC environment detection and diagnostics

## Plotting

Using the included [dependencies.sh](./dependencies.sh) and [env-setup.sh](./env-setup.sh) takes care of setup and linking to pyplot-fortran with the `$FFLAGS`/`$PFFLAGS` and `$FLIBS` environment variables.

<img src="media/fortscript_sine.png" width="400" />
<img src="media/fortscript_scatter.png" width="400" />
<img src="media/fortscript_hist.png" width="400" />
<img src="media/fortscript_imshow.png" width="400" />
<img src="media/fortscript_contour.png" width="400" />
<img src="media/fortscript_contourf.png" width="400" />

## Acknowledgements
Source code archives from the following projects (including their original licenses) are included in the _depends/_ folder:
- https://github.com/sourceryinstitute/OpenCoarrays
- https://github.com/jacobwilliams/pyplot-fortran
- https://github.com/geospace-code/h5fortran

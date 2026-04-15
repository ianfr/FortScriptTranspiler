#!/bin/zsh

source env-setup.sh

mkdir -p out && rm -rf out/*

step() {
    echo "[build-examples] $1"  # Short trace label for each step.
}

step "transpile parallel_bench" && \
 _build/default/bin/main.exe examples/parallel_bench.py -o out/parallel_bench.f90 && \
step "transpile dynamic_arrays" && \
 _build/default/bin/main.exe examples/dynamic_arrays.py -o out/dynamic_arrays.f90 && \
step "transpile heat_diffusion" && \
 _build/default/bin/main.exe examples/heat_diffusion.py -o out/heat_diffusion.f90 && \
step "transpile import_demo" && \
 _build/default/bin/main.exe examples/import_demo.py -o out/import_demo.f90 && \
step "transpile nbody" && \
 _build/default/bin/main.exe examples/nbody.py -o out/nbody.f90 && \
step "transpile slicing" && \
 _build/default/bin/main.exe examples/slicing.py -o out/slicing.f90 && \
step "transpile plotting" && \
 _build/default/bin/main.exe examples/plotting.py -o out/plotting.f90 && \
step "transpile support_linalg" && \
 _build/default/bin/main.exe examples/support_linalg.py -o out/support_linalg.f90 && \
step "transpile support_optimize" && \
 _build/default/bin/main.exe examples/support_optimize.py -o out/support_optimize.f90 && \
step "transpile coarray_hello" && \
 _build/default/bin/main.exe examples/coarray_hello.py -o out/coarray_hello.f90 && \
step "transpile coarray_gather" && \
 _build/default/bin/main.exe examples/coarray_gather.py -o out/coarray_gather.f90 && \
step "transpile coarray_multiple_codims" && \
 _build/default/bin/main.exe examples/coarray_multiple_codims.py -o out/coarray_multiple_codims.f90 && \
step "transpile do_concurrent_features" && \
 _build/default/bin/main.exe examples/do_concurrent_features.py -o out/do_concurrent_features.f90 && \
step "transpile coarray_collective_operations" && \
 _build/default/bin/main.exe examples/coarray_collective_operations.py -o out/coarray_collective_operations.f90 && \
step "transpile hdf5_io" && \
 _build/default/bin/main.exe examples/hdf5_io.py -o out/hdf5_io.f90

cd out
step "compile parallel_bench" && \
gfortran $(echo $PFFLAGS) -o parallel_bench parallel_bench.f90 && \
step "compile dynamic_arrays" && \
gfortran $(echo $FFLAGS) -o dynamic_arrays dynamic_arrays.f90 && \
step "compile heat_diffusion" && \
gfortran $(echo $FFLAGS) -o heat_diffusion heat_diffusion.f90 && \
step "compile import_demo" && \
gfortran $(echo $FFLAGS) -o import_demo import_demo.f90 && \
step "compile nbody" && \
gfortran $(echo $FFLAGS) -o nbody nbody.f90 && \
step "compile slicing" && \
gfortran $(echo $FFLAGS) -o slicing slicing.f90 && \
step "compile plotting" && \
gfortran $(echo $FFLAGS) -o plotting plotting.f90 $(echo $FLIBS) && \
step "compile support_linalg" && \
gfortran $(echo $FFLAGS) -o support_linalg support_linalg.f90 $(echo $FLIBS) && \
step "compile support_optimize" && \
gfortran $(echo $FFLAGS) -o support_optimize support_optimize.f90 && \
step "compile coarray_hello" && \
caf $(echo $FFLAGS) -o coarray_hello coarray_hello.f90 && \
step "compile coarray_gather" && \
caf $(echo $FFLAGS) -o coarray_gather coarray_gather.f90 && \
caf $(echo $FFLAGS) -o coarray_hello coarray_hello.f90 && \
step "compile coarray_multiple_codims" && \
caf $(echo $PFFLAGS) -o coarray_multiple_codims coarray_multiple_codims.f90 && \
step "compile do_concurrent_features" && \
gfortran $(echo $PFFLAGS) -o do_concurrent_features do_concurrent_features.f90 && \
step "compile coarray_collective_operations" && \
caf $(echo $FFLAGS) -o coarray_collective_operations coarray_collective_operations.f90 && \
step "compile hdf5_io" && \
gfortran $(echo $FFLAGS) -o hdf5_io hdf5_io.f90 $(echo $FLIBS)

cd ..

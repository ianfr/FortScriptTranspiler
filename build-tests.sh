#!/bin/zsh

source env-setup.sh

mkdir -p out && rm -rf out/*

# Add runtime bounds and argument checking on top of the standard flags.
export TFLAGS="$FFLAGS -fcheck=all"

step() {
    echo "[build-tests] $1"  # Short trace label for each step.
}

# --- Transpile ---
step "transpile test_arithmetic" && \
 _build/default/bin/main.exe tests/test_arithmetic.py -o out/test_arithmetic.f90 && \
step "transpile test_control_flow" && \
 _build/default/bin/main.exe tests/test_control_flow.py -o out/test_control_flow.f90 && \
step "transpile test_functions" && \
 _build/default/bin/main.exe tests/test_functions.py -o out/test_functions.f90 && \
step "transpile test_array_1d" && \
 _build/default/bin/main.exe tests/test_array_1d.py -o out/test_array_1d.f90 && \
step "transpile test_array_2d" && \
 _build/default/bin/main.exe tests/test_array_2d.py -o out/test_array_2d.f90 && \
step "transpile test_slicing" && \
 _build/default/bin/main.exe tests/test_slicing.py -o out/test_slicing.f90 && \
step "transpile test_structs" && \
 _build/default/bin/main.exe tests/test_structs.py -o out/test_structs.f90 && \
step "transpile test_do_concurrent" && \
 _build/default/bin/main.exe tests/test_do_concurrent.py -o out/test_do_concurrent.f90 && \
step "transpile test_do_concurrent_reductions" && \
 _build/default/bin/main.exe tests/test_do_concurrent_reductions.py -o out/test_do_concurrent_reductions.f90 && \
step "transpile test_imports" && \
 _build/default/bin/main.exe tests/test_imports.py -o out/test_imports.f90 && \
# GPU extraction is a transpile-only check here; linking requires nvfortran on Linux.
step "transpile test_gpu_codegen" && \
 _build/default/bin/main.exe tests/test_gpu_codegen.py -o out/test_gpu_codegen.f90

cd out

# --- Compile (all use TFLAGS which includes -fcheck=all) ---
step "compile test_arithmetic" && \
gfortran $(echo $TFLAGS) -o test_arithmetic test_arithmetic.f90 && \
step "compile test_control_flow" && \
gfortran $(echo $TFLAGS) -o test_control_flow test_control_flow.f90 && \
step "compile test_functions" && \
gfortran $(echo $TFLAGS) -o test_functions test_functions.f90 && \
step "compile test_array_1d" && \
gfortran $(echo $TFLAGS) -o test_array_1d test_array_1d.f90 && \
step "compile test_array_2d" && \
gfortran $(echo $TFLAGS) -o test_array_2d test_array_2d.f90 && \
step "compile test_slicing" && \
gfortran $(echo $TFLAGS) -o test_slicing test_slicing.f90 && \
step "compile test_structs" && \
gfortran $(echo $TFLAGS) -o test_structs test_structs.f90 && \
step "compile test_do_concurrent" && \
gfortran $(echo $TFLAGS) -o test_do_concurrent test_do_concurrent.f90 && \
step "compile test_do_concurrent_reductions" && \
gfortran $(echo $TFLAGS) -o test_do_concurrent_reductions test_do_concurrent_reductions.f90 && \
step "compile test_imports" && \
gfortran $(echo $TFLAGS) -o test_imports test_imports.f90

cd ..

#!/bin/bash

# Build and time all FortScript benchmarks using time -p.
# Set FS_N_CORES before sourcing env-setup to control parallelism.

export FS_N_CORES=20

# Supress UCX warnings during MPI cleanup that print a lot of lines
export UCX_LOG_LEVEL=error

source env-setup.sh

step() {
    echo "[run-benchmarks] $1"
}

time_run() {
    local label=$1
    shift
    echo ""
    step "=== $label ==="
    time -p "$@" 2>&1
}

# Build all benchmarks first.
step "building benchmarks..."
bash build-benchmarks.sh || { echo "Build failed"; exit 1; }

echo ""
step "running benchmarks with FS_N_CORES=$FS_N_CORES"

# Ising Glauber benchmarks
time_run "ising_glauber_serial"        ./out/ising_glauber_serial
time_run "ising_glauber_do_concurrent" ./out/ising_glauber_do_concurrent
time_run "ising_glauber_coarray"       cafrun -np $FS_N_CORES ./out/ising_glauber_coarray

# Molecular dynamics benchmarks
time_run "md_serial"        ./out/md_serial
time_run "md_do_concurrent" ./out/md_do_concurrent
time_run "md_coarray"       cafrun -np $FS_N_CORES ./out/md_coarray

# Shallow water benchmarks
time_run "shallow_water_serial"        ./out/shallow_water_serial
time_run "shallow_water_do_concurrent" ./out/shallow_water_do_concurrent
time_run "shallow_water_coarray"       cafrun -np $FS_N_CORES ./out/shallow_water_coarray

step "done"

#!/bin/zsh

source env-setup.sh

mkdir -p out && rm -rf out/*

step() {
    echo "[build-benchmarks] $1"  # Short trace label for each step.
}

step "transpile md_serial" && \
dune exec bin/main.exe -- benchmarks/md_serial.py -o out/md_serial.f90 && \
step "transpile md_do_concurrent" && \
dune exec bin/main.exe -- benchmarks/md_do_concurrent.py -o out/md_do_concurrent.f90 && \
step "transpile md_coarray" && \
dune exec bin/main.exe -- benchmarks/md_coarray.py -o out/md_coarray.f90 && \
step "transpile laplace_2d_serial" && \
dune exec bin/main.exe -- benchmarks/laplace_2d_serial.py -o out/laplace_2d_serial.f90 && \
step "transpile laplace_2d_do_concurrent" && \
dune exec bin/main.exe -- benchmarks/laplace_2d_do_concurrent.py -o out/laplace_2d_do_concurrent.f90 && \
step "transpile laplace_2d_coarray" && \
dune exec bin/main.exe -- benchmarks/laplace_2d_coarray.py -o out/laplace_2d_coarray.f90

cd out
step "compile md_serial" && \
gfortran $(echo $FFLAGS) -o md_serial md_serial.f90 && \
step "compile md_do_concurrent" && \
gfortran $(echo $PFFLAGS) -o md_do_concurrent md_do_concurrent.f90 && \
step "compile md_coarray" && \
caf $(echo $PFFLAGS) -o md_coarray md_coarray.f90 && \
step "compile laplace_2d_serial" && \
gfortran $(echo $FFLAGS) -o laplace_2d_serial laplace_2d_serial.f90 && \
step "compile laplace_2d_do_concurrent" && \
gfortran $(echo $PFFLAGS) -o laplace_2d_do_concurrent laplace_2d_do_concurrent.f90 && \
step "compile laplace_2d_coarray" && \
caf $(echo $FFLAGS) -o laplace_2d_coarray laplace_2d_coarray.f90

cd ..

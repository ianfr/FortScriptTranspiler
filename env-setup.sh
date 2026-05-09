# Environment variables & transpiler build
# NOTE: Assumes dependencies have been installed/built with dependencies.sh
# Source this before running FortScript commands
source ~/.bashrc
if command -v opam >/dev/null 2>&1 && opam env >/dev/null 2>&1; then
  eval "$(opam env)"
fi

dune build

# For MPICH UCX, added with switch to Docker for development
export MPIR_CVAR_CH4_NETMOD=ucx
export UCX_TLS=self,cma,sm

# pyplot dependency
export PYPL_INC=$(realpath depends/pyplot)
export PYPL_LIB=$PYPL_INC

# h5fortran dependency
export H5F_INC=$(realpath depends/h5fortran-main/build/include)
export HF5_LIB=$(realpath depends/h5fortran-main/build)

RPATH_FLAGS="-Wl,-rpath,$PYPL_LIB -Wl,-rpath,$HF5_LIB"
if [ -n "$HDF5_PREFIX" ]; then
  RPATH_FLAGS="$RPATH_FLAGS -Wl,-rpath,$HDF5_PREFIX/lib"
fi

if [ -z "$FS_N_CORES" ]; then
  FS_N_CORES=10
fi

echo "Setting compiler flags with FS_N_CORES=$FS_N_CORES"

export FFLAGS="-O3 -march=native -std=f2018 -ffree-line-length-none -I$PYPL_INC -I$H5F_INC $(pkg-config --cflags hdf5-serial)"

export FLIBS="-L$PYPL_LIB -L$HF5_LIB $RPATH_FLAGS -lh5fortran -lhdf5hl_fortran -lhdf5_fortran $(pkg-config --libs hdf5-serial) -lpyplot-fortran -llapack -lblas"

# Extra flags when using "@par" in FortScript
# -finline-limit=5000 lets gfortran inline @par helper functions into their
# callers, exposing allocatable array layout to the autoparallelizer.
export PFFLAGS="$FFLAGS -ftree-parallelize-loops=$FS_N_CORES -finline-limit=5000 -fopt-info-loop -fopenmp"

# NVIDIA stdpar GPU support uses nvfortran and is only supported on Linux.
export NVFORTRAN="${NVFORTRAN:-nvfortran}"
export NVFLAGS="${NVFLAGS:--O3 -stdpar=gpu -Minfo=stdpar -Mfree}"
export GPUFFLAGS="$FFLAGS"
export GPU_LINK_LIBS="$FLIBS -lgfortran -lquadmath"

# Takes one arg, the path to the fortscript file
fs_build_gpu() {
  local src=$1
  local base
  local host_obj
  local host_src
  local gpu_lib
  local out_exe
  local gpu_sources
  local gpu_objects=()
  base=$(basename "$src" .py)
  host_src="./out/${base}.f90"
  host_obj="./out/${base}_host.o"
  gpu_lib="./out/libgpu_kernels.a"
  out_exe="./out/${base}"

  if [ "$(uname -s)" != "Linux" ]; then
    echo "GPU builds with nvfortran are only supported on Linux."
    return 1
  fi

  mkdir -p ./out
  rm -f ./out/*_gpu.f90 ./out/*_gpu.o "$gpu_lib" "$host_src" "$host_obj" "$out_exe"

  _build/default/bin/main.exe "$src" -o "$host_src" || return 1

  gpu_sources=()
  local candidate
  for candidate in ./out/*_gpu.f90; do
    [ -e "$candidate" ] || continue
    if [ "$candidate" != "./out/${base}.f90" ]; then
      gpu_sources+=( "$candidate" )
    fi
  done

  if [ ${#gpu_sources[@]} -gt 0 ]; then
    for gpu_src in "${gpu_sources[@]}"; do
      local gpu_obj="${gpu_src%.f90}.o"
      "$NVFORTRAN" $(echo $NVFLAGS) -c "$gpu_src" -o "$gpu_obj" || return 1
      gpu_objects+=( "$gpu_obj" )
    done
    ar rcs "$gpu_lib" "${gpu_objects[@]}" || return 1
    gfortran $(echo $GPUFFLAGS) -c -o "$host_obj" "$host_src" || return 1
    "$NVFORTRAN" $(echo $NVFLAGS) -Mnomain -o "$out_exe" "$host_obj" "$gpu_lib" $(echo $GPU_LINK_LIBS) || return 1
  else
    echo "WARNING, no gpu kernels detected"
    # gfortran $(echo $PFFLAGS) -o "$base" "${base}.f90" || return 1
  fi
}

# Environment variables & transpiler build
# NOTE: Assumes dependencies have been installed/built with dependencies.sh
# Source this before running FortScript commands

eval "$(opam env)"
dune build

# pyplot dependency
export PYPL_INC=$(realpath depends/pyplot)
export PYPL_LIB=$PYPL_INC

# h5fortran dependency
export H5F_INC=$(realpath depends/h5fortran-main/build/include)
export HF5_LIB=$(realpath depends/h5fortran-main/build)

# Locate the underlying HDF5 install (h5fortran wraps the C/Fortran HDF5 libs).
# On macOS the homebrew prefix is the easiest way to find them; on Linux we
# fall back to the conda environment that dependencies.sh sets up.
if command -v brew >/dev/null 2>&1; then
  HDF5_PREFIX=$(brew --prefix hdf5 2>/dev/null)
fi
if [ -z "$HDF5_PREFIX" ] && [ -n "$CONDA_PREFIX" ]; then
  HDF5_PREFIX=$CONDA_PREFIX
fi
export HDF5_PREFIX

HDF5_INC_FLAG=""
HDF5_LIB_FLAG=""
if [ -n "$HDF5_PREFIX" ]; then
  HDF5_INC_FLAG="-I$HDF5_PREFIX/include"
  HDF5_LIB_FLAG="-L$HDF5_PREFIX/lib"
fi

RPATH_FLAGS="-Wl,-rpath,$PYPL_LIB -Wl,-rpath,$HF5_LIB"
if [ -n "$HDF5_PREFIX" ]; then
  RPATH_FLAGS="$RPATH_FLAGS -Wl,-rpath,$HDF5_PREFIX/lib"
fi

export FFLAGS="-O2 -std=f2018 -ffree-line-length-none -I$PYPL_INC -I$H5F_INC $HDF5_INC_FLAG"

export FLIBS="-L$PYPL_LIB -L$HF5_LIB $HDF5_LIB_FLAG $RPATH_FLAGS -lh5fortran -lhdf5_hl_fortran -lhdf5_hl -lhdf5_fortran -lhdf5 -lpyplot-fortran -llapack -lblas"

# Extra flags when using "@par" in FortScript
# -finline-limit=5000 lets gfortran inline @par helper functions into their
# callers, exposing allocatable array layout to the autoparallelizer.
export PFFLAGS="$FFLAGS -ftree-parallelize-loops=10 -finline-limit=5000 -fopt-info-loop -fopenmp"

# NVIDIA stdpar GPU support uses nvfortran and is only supported on Linux.
if [ "$(uname -s)" = "Linux" ]; then
  export NVFORTRAN="${NVFORTRAN:-nvfortran}"
  export NVFLAGS="${NVFLAGS:--O3 -stdpar=gpu -Minfo=stdpar -Mfree}"
  export GPUFFLAGS="$FFLAGS"
  export GPU_LINK_LIBS="$FLIBS -lgfortran -lquadmath"
fi

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

# Environment variables & transpiler build
# Source this before running commands in the README

eval "$(opam env)"
dune build

# NOTE: These are unique every time pyplot is built?
if [ "$(uname)" = "Linux" ]; then
    export PYPL_INC=/mnt/c/Users/ianfr/coding-local/pyplot-fortran/build/gfortran_C3CACAC4D0122D28/pyplot-fortran
    export PYPL_INC2=/mnt/c/Users/ianfr/coding-local/pyplot-fortran/build/gfortran_C3CACAC4D0122D28 # for .mod
    export PYPL_LIB=/mnt/c/Users/ianfr/coding-local/pyplot-fortran/build/gfortran_24C83E9D044ED2EE/pyplot-fortran
else
    export PYPL_INC=/Users/ian/pyplot-fortran/build/gfortran_C3CACAC4D0122D28
    export PYPL_LIB=/Users/ian/pyplot-fortran/build/gfortran_24C83E9D044ED2EE/pyplot-fortran
fi

# Flags for normal compilation
# The line-length flag keeps long generated expressions valid in free-form Fortran.

if [ "$(uname)" = "Linux" ]; then
    export FFLAGS="-O2 -std=f2018 -ffree-line-length-none -I$PYPL_INC -I$PYPL_INC2"
else
    export FFLAGS="-O2 -std=f2018 -ffree-line-length-none -I$PYPL_INC"
fi

export FLIBS="-L$PYPL_LIB -lpyplot-fortran -llapack -lblas"

# Extra flags when using "@par" in FortScript
# -finline-limit=5000 lets gfortran inline @par helper functions into their
# callers, exposing allocatable array layout to the autoparallelizer.
export PFFLAGS="$FFLAGS -ftree-parallelize-loops=10 -finline-limit=5000 -fopt-info-loop"

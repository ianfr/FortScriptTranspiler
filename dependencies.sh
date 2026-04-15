# Build and install dependencies for the project

# ===============================================================================
# Make sure package manager is available before continuing
# ===============================================================================
if [ "$(uname)" = "Linux" ]; then
    if type conda &> /dev/null; then
        echo "Found required package manager: conda for Linux"
    else
        echo "ERROR: conda must be installed on Linux. Try https://github.com/conda-forge/miniforge"
        exit 1
    fi
else # macOS
    if type brew &> /dev/null; then
        echo "Found required package manager: Homebrew for macOS"
    else
        echo "ERROR: Homebrew must be installed on macOS. See https://brew.sh/"
        exit 1
    fi
fi

# ===============================================================================
# Install packages
# ===============================================================================
if [ "$(uname)" = "Linux" ]; then
    # Everything gets installed right from conda
    conda env create -f linux-environment.yml
    conda activate fortscript
else # macOS
    brew install opam gfortran python3 python-matplotlib opencoarrays hdf5 cmake
    opam install menhir dune
fi

# ===============================================================================
# Build dependencies (OpenCoarrays, pyplot-fortran, etc.)
# ===============================================================================

# Only build OpenCoarrays from source on Linux
# TODO: Test this, have only done it manually before
if [ "$(uname)" = "Linux" ]; then
    cd depends
    unzip OpenCoarrays.zip
    mkdir build-opencoarrays && cd build-opencoarrays 
    cmake -DBUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$CONDA_PREFIX ../OpenCoarrays-main
    make -j8
    make test
    make install
    echo "Installed OpenCoarrays to $CONDA_PREFIX"
    cd ..
fi

# Build pyplot-fortran and extract shared libraries automatically
cd depends
unzip pyplot-fortran.zip
cd pyplot-fortran-master
fpm build --profile release
mkdir -p ../pyplot
cp $(find build -name libpyplot-fortran.a) ../pyplot
cp $(find build -name "*.mod") ../pyplot
cd ../..

# Build h5fortran for HDF5 I/O support
cd depends
unzip h5fortran.zip
cd h5fortran-main
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
cd ../../

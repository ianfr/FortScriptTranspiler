# Build and install dependencies for the project
set -e

cd depends
rm -rf  build-opencoarrays opencoarrays pyplot-fortran-master h5fortran-main OpenCoarrays-main pyplot caffeine
cd ..

# Make sure package manager is available before continuing
if [ "$(uname)" != "Linux" ]; then
    echo "ERROR: local dependency installation is supported only on Linux. Use Docker on other systems."
    exit 1
fi

# Install packages
if type apt &> /dev/null; then
        echo "Found apt for Linux"
else
    echo "ERROR: only systems with apt (Debian, Ubuntu etc.) are tested for linux"
    exit 1
fi

sudo apt update && sudo apt install -y git cmake make ninja-build binutils python3 python3-numpy python3-matplotlib gfortran gcc opam build-essential curl bubblewrap unzip sudo pipx
sudo apt install -y libhdf5-dev libopenblas-dev libmpich-dev
# sudo apt install libcoarrays-mpich-dev
# sudo apt install libcoarrays-openmpi-dev libopenmpi-dev openmpi-bin

# Install the fortran package manager
# https://fpm.fortran-lang.org/install/index.html#pip-package-manager
pipx install fpm
pipx ensurepath
# source ~/.bashrc
export PATH="$PATH:/home/ubuntu/.local/bin"

# ===============================================================================
# Build dependencies (pyplot-fortran, etc.)
# ===============================================================================

cd depends

# Build OpenCoarrays from source into the active conda environment.
unzip -o OpenCoarrays.zip
rm -rf build-opencoarrays
mkdir build-opencoarrays && cd build-opencoarrays
mkdir -p $HOME/oca_prefix
OCA_PREFIX=$HOME/oca_prefix
OCA_CC=${CC:-gcc}
OCA_CXX=${CXX:-g++}
OCA_FC=${FC:-gfortran}
env -u FFLAGS -u FCFLAGS -u CFLAGS -u CXXFLAGS \
    CC="$OCA_CC" CXX="$OCA_CXX" FC="$OCA_FC" \
    cmake -GNinja -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_INSTALL_PREFIX="$OCA_PREFIX" \
          -DCMAKE_C_COMPILER="$OCA_CC" \
          -DCMAKE_CXX_COMPILER="$OCA_CXX" \
          -DCMAKE_Fortran_COMPILER="$OCA_FC" \
          -DCMAKE_Fortran_FLAGS="" \
          ../OpenCoarrays-main
# cmake --build . --target caf_mpi caf_mpi_static opencoarrays_mod --parallel 8
cmake --build . --parallel 8
cmake --install .
echo "Installed OpenCoarrays to $OCA_PREFIX"
cd ../..
echo 'export OCA_PREFIX=$HOME/oca_prefix' >> ~/.bashrc
echo 'export PATH="$PATH:$OCA_PREFIX:$OCA_PREFIX/bin:$OCA_PREFIX/lib"' >> ~/.bashrc
source ~/.bashrc

# Might switch to PRIF in the future
# git clone https://github.com/BerkeleyLab/caffeine.git
# cd caffeine
# env FC=gfortran CC=gcc CXX=g++ ./install.sh --enable-threads --yes
# env CAF_IMAGES=8 ./run-fpm.sh run --example hello
# cd ..

# Build pyplot-fortran and extract shared libraries automatically
cd depends
unzip -o pyplot-fortran.zip
cd pyplot-fortran-master
fpm build --profile release
mkdir -p ../pyplot
cp $(find build -name libpyplot-fortran.a) ../pyplot
cp $(find build -name "*.mod") ../pyplot
cd ../..

# Build h5fortran for HDF5 I/O support
cd depends
unzip -o h5fortran.zip
cd h5fortran-main
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel 8
cd ../../

# Set up the OCaml environment
opam init --disable-sandboxing -a -y
source ~/.bashrc
eval $(opam env)
opam install dune menhir -y

# HDF5 I/O demo: write and then read back scalars and 1D/2D/3D arrays
# all from the same .h5 file using the h5fortran high-level interface.

def main():
    # ----- Build the data we want to persist -----
    pi_val: float = 3.14159265358979  # scalar float
    answer: int = 42                  # scalar int

    x1d: array[float, :]              # 1D dynamic float array
    x2d: array[float, :, :]           # 2D dynamic float array
    x3d: array[float, :, :, :]        # 3D dynamic float array

    x1d = linspace(0.0, 1.0, 5)
    x2d = reshape(linspace(1.0, 6.0, 6), [2, 3])
    x3d = reshape(linspace(1.0, 24.0, 24), [2, 3, 4])

    # ----- Write everything into one .h5 file -----
    # Each h5write call opens the file, writes the dataset, and closes it.
    h5write("hdf5_demo.h5", "/pi", pi_val)
    h5write("hdf5_demo.h5", "/answer", answer)
    h5write("hdf5_demo.h5", "/x1d", x1d)
    h5write("hdf5_demo.h5", "/x2d", x2d)
    h5write("hdf5_demo.h5", "/x3d", x3d)

    # ----- Read everything back into fresh variables -----
    pi_in: float = 0.0
    answer_in: int = 0

    y1d: array[float, :]
    y2d: array[float, :, :]
    y3d: array[float, :, :, :]

    # h5read writes into pre-existing storage, so dynamic destinations
    # must be allocated to match the on-disk shape before the call.
    allocate(y1d, 5)
    allocate(y2d, 2, 3)
    allocate(y3d, 2, 3, 4)

    h5read("hdf5_demo.h5", "/pi", pi_in)
    h5read("hdf5_demo.h5", "/answer", answer_in)
    h5read("hdf5_demo.h5", "/x1d", y1d)
    h5read("hdf5_demo.h5", "/x2d", y2d)
    h5read("hdf5_demo.h5", "/x3d", y3d)

    # ----- Show the round-tripped values -----
    print("pi:", pi_in)
    print("answer:", answer_in)
    print("y1d[0]:", y1d[0], "y1d[4]:", y1d[4])
    print("y2d[0,0]:", y2d[0, 0], "y2d[1,2]:", y2d[1, 2])
    print("y3d[0,0,0]:", y3d[0, 0, 0], "y3d[1,2,3]:", y3d[1, 2, 3])

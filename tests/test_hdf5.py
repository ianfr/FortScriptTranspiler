# Test h5write/h5read round-trip for scalars and 1D/2D arrays.
# Requires linking against h5fortran and HDF5.

def main():
    pi_val: float = 3.14159
    answer: int = 42
    x1d: array[float, :] = linspace(0.0, 1.0, 5)
    x2d: array[float, :, :] = reshape(linspace(1.0, 6.0, 6), [2, 3])

    pi_in: float = 0.0
    answer_in: int = 0
    y1d: array[float, :]
    y2d: array[float, :, :]

    # Write a mix of scalars and arrays into one file.
    h5write("test_hdf5.h5", "/pi", pi_val)
    h5write("test_hdf5.h5", "/answer", answer)
    h5write("test_hdf5.h5", "/x1d", x1d)
    h5write("test_hdf5.h5", "/x2d", x2d)

    # Allocate destinations to match the on-disk shapes before reading.
    allocate(y1d, 5)
    allocate(y2d, 2, 3)

    h5read("test_hdf5.h5", "/pi", pi_in)
    h5read("test_hdf5.h5", "/answer", answer_in)
    h5read("test_hdf5.h5", "/x1d", y1d)
    h5read("test_hdf5.h5", "/x2d", y2d)

    if abs(pi_in - 3.14159) > 1.0e-6:
        exit(1)
    if not (answer_in == 42):
        exit(1)
    if abs(y1d[0]) > 1.0e-9:
        exit(1)
    if abs(y1d[4] - 1.0) > 1.0e-9:
        exit(1)
    if abs(y2d[0, 0] - 1.0) > 1.0e-9:
        exit(1)
    if abs(y2d[1, 2] - 6.0) > 1.0e-9:
        exit(1)

    print("test_hdf5: all checks passed")

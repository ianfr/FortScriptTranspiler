# Test append on a deferred-shape 1D array.

def main():
    xs: array[float, :]

    # The first append allocates length one.
    append(xs, 1.5)
    if abs(xs[0] - 1.5) > 1.0e-12:
        exit(1)

    # Later appends preserve existing values.
    append(xs, 2.5)
    append(xs, -3.0)
    if abs(xs[0] - 1.5) > 1.0e-12:
        exit(1)
    if abs(xs[1] - 2.5) > 1.0e-12:
        exit(1)
    if abs(xs[2] + 3.0) > 1.0e-12:
        exit(1)

    print("test_append: all checks passed")

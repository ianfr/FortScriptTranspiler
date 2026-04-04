# FortScript linear algebra support library
# Mimics functionality present in https://numpy.org/doc/stable/reference/routines.linalg.html
# BLAS / LAPACK are used when possible

# QR decomposition
def qr(a: array[float, :, :], q: array[float, :, :], r: array[float, :, :]):
    pass  # The compiler lowers this stub to a generated LAPACK helper.

# Solve a square linear system A x = b for a vector right-hand side.
def solve(a: array[float, :, :], b: array[float, :], x: array[float, :]):
    pass  # The compiler lowers this stub to a generated LAPACK helper.

# Reduced singular value decomposition
def svd(a: array[float, :, :], u: array[float, :, :], s: array[float, :], vt: array[float, :, :]):
    pass  # The compiler lowers this stub to a generated LAPACK helper.

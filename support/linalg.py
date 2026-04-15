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

# Eigenvalues and right eigenvectors of a real general matrix.
# Eigenvalues are returned as separate real (wr) and imaginary (wi) parts because
# FortScript has no complex type. The eigenvector layout in vr follows the LAPACK
# dgeev convention: real eigenvalues use a single column; complex conjugate pairs
# occupy two consecutive columns holding the real and imaginary parts.
def eig(a: array[float, :, :], wr: array[float, :], wi: array[float, :], vr: array[float, :, :]):
    pass  # The compiler lowers this stub to a generated LAPACK helper.

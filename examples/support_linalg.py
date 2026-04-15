# support.linalg showcase ready for more helpers later.

import support.linalg

def test_qr():
    a: array[float, :, :]  # Input matrix for reduced QR
    q: array[float, :, :]  # Reduced Q with shape (m, k)
    r: array[float, :, :]  # Reduced R with shape (k, n)
    rebuilt: array[float, :, :]  # Product q @ r for a quick check
    gram: array[float, :, :]  # Q^T Q should be close to identity

    a = reshape([12.0, -51.0, 4.0, 6.0, 167.0, -68.0, -4.0, 24.0, -41.0], [3, 3])
    q = reshape(zeros(9), [3, 3])  # Preallocate the outputs the LAPACK helper fills.
    r = reshape(zeros(9), [3, 3])  # This example keeps the matrix square.

    qr(a, q, r)

    rebuilt = matmul(q, r)
    gram = matmul(transpose(q), q)

    print("qr q[0, 0]:", q[0, 0])
    print("qr r[0, 1]:", r[0, 1])
    print("qr rebuilt[2, 1]:", rebuilt[2, 1])
    print("qr q^t q[1, 1]:", gram[1, 1])

def test_solve():
    a: array[float, :, :]  # Square coefficient matrix A.
    b: array[float, :]  # Right-hand side vector b.
    x: array[float, :]  # Output vector filled by the LAPACK helper.
    check0: float  # First reconstructed entry of A x.
    check1: float  # Second reconstructed entry of A x.

    a = reshape([3.0, 1.0, 1.0, 2.0], [2, 2])
    b = [9.0, 8.0]
    x = zeros(2)  # Preallocate the output vector the helper fills.

    solve(a, b, x)

    check0 = a[0, 0] * x[0] + a[0, 1] * x[1]  # Rebuild the first row product.
    check1 = a[1, 0] * x[0] + a[1, 1] * x[1]  # Rebuild the second row product.

    print("solve x[0]:", x[0])
    print("solve x[1]:", x[1])
    print("solve ax[0]:", check0)
    print("solve ax[1]:", check1)

def test_svd():
    a: array[float, :, :]  # Input matrix for reduced SVD
    u: array[float, :, :]  # Reduced U with shape (m, k)
    s: array[float, :]  # Singular values with length k
    vt: array[float, :, :]  # Reduced V^T with shape (k, n)
    sigma: array[float, :, :]  # Diagonal matrix built from s for reconstruction
    rebuilt: array[float, :, :]  # Product u @ sigma @ vt for a quick check
    left_gram: array[float, :, :]  # U^T U should be close to identity

    a = reshape([3.0, 1.0, 1.0, -1.0, 3.0, 1.0, 0.0, 0.0, 2.0], [3, 3])
    u = reshape(zeros(9), [3, 3])  # Reduced U for this square example is still 3x3.
    s = zeros(3)
    vt = reshape(zeros(9), [3, 3])  # Reduced V^T for this square example is still 3x3.
    sigma = reshape(zeros(9), [3, 3])

    svd(a, u, s, vt)

    for i in range(3):
        sigma[i, i] = s[i]  # Build Sigma explicitly because there is no diag() builtin yet.

    rebuilt = matmul(u, matmul(sigma, vt))
    left_gram = matmul(transpose(u), u)

    print("svd s[0]:", s[0])
    print("svd u[0, 0]:", u[0, 0])
    print("svd vt[0, 1]:", vt[0, 1])
    print("svd rebuilt[1, 2]:", rebuilt[1, 2])
    print("svd u^t u[1, 1]:", left_gram[1, 1])

def test_eig():
    a: array[float, :, :]  # Square input matrix whose eigenpairs we want.
    wr: array[float, :]  # Real parts of the eigenvalues.
    wi: array[float, :]  # Imaginary parts of the eigenvalues.
    vr: array[float, :, :]  # Right eigenvectors in LAPACK packed layout.
    av: array[float, :]  # Reconstructed A v for the first eigenvector.
    lv: array[float, :]  # Reconstructed lambda v for the first eigenvector.
    trace: float  # Trace of A: should equal sum(wr) for any real matrix.
    sum_wr: float  # Sum of real eigenvalue parts.

    # Symmetric 3x3 matrix so all eigenvalues are real and the test is reproducible.
    a = reshape([4.0, 1.0, 2.0, 1.0, 3.0, 0.0, 2.0, 0.0, 5.0], [3, 3])
    wr = zeros(3)  # Preallocate the outputs the LAPACK helper fills.
    wi = zeros(3)
    vr = reshape(zeros(9), [3, 3])

    eig(a, wr, wi, vr)

    # Verify A v0 == lambda0 v0 for the first eigenpair.
    av = matmul(a, vr[:, 0])
    lv = vr[:, 0]
    for i in range(3):
        lv[i] = wr[0] * lv[i]  # Scale eigenvector by its eigenvalue.

    trace = a[0, 0] + a[1, 1] + a[2, 2]  # Sum of diagonal entries.
    sum_wr = wr[0] + wr[1] + wr[2]  # Sum of eigenvalues (real parts).

    print("eig wr[0]:", wr[0])
    print("eig wi[0]:", wi[0])
    print("eig vr[0, 0]:", vr[0, 0])
    print("eig av[0]:", av[0])
    print("eig lambda*v[0]:", lv[0])
    print("eig trace:", trace)
    print("eig sum(wr):", sum_wr)

def main():
    test_qr()
    test_solve()
    test_svd()
    test_eig()

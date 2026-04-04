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

def main():
    test_qr()
    test_solve()
    test_svd()

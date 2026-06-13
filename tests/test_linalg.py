# Test support.linalg: solve, qr, svd, eig on small matrices.
# Requires linking against LAPACK and BLAS.

import support.linalg

def main():
    a: array[float, :, :]
    b: array[float, :]
    x: array[float, :]
    q: array[float, :, :]
    r: array[float, :, :]
    rebuilt: array[float, :, :]
    u: array[float, :, :]
    s: array[float, :]
    vt: array[float, :, :]
    wr: array[float, :]
    wi: array[float, :]
    vr: array[float, :, :]
    trace: float = 0.0
    sum_wr: float = 0.0

    # 2x2 linear solve: [[3,1],[1,2]] x = [9,8] -> x = [2, 3]
    a = reshape([3.0, 1.0, 1.0, 2.0], [2, 2])
    b = [9.0, 8.0]
    x = zeros(2)
    solve(a, b, x)
    if abs(x[0] - 2.0) > 1.0e-9:
        exit(1)
    if abs(x[1] - 3.0) > 1.0e-9:
        exit(1)

    # QR factorization: Q*R should rebuild A
    q = reshape(zeros(4), [2, 2])
    r = reshape(zeros(4), [2, 2])
    qr(a, q, r)
    rebuilt = matmul(q, r)
    if abs(rebuilt[0, 0] - a[0, 0]) > 1.0e-9:
        exit(1)
    if abs(rebuilt[1, 0] - a[1, 0]) > 1.0e-9:
        exit(1)
    if abs(rebuilt[0, 1] - a[0, 1]) > 1.0e-9:
        exit(1)
    if abs(rebuilt[1, 1] - a[1, 1]) > 1.0e-9:
        exit(1)

    # SVD: singular values are non-negative and sorted descending
    u = reshape(zeros(4), [2, 2])
    s = zeros(2)
    vt = reshape(zeros(4), [2, 2])
    svd(a, u, s, vt)
    if s[0] < 0.0:
        exit(1)
    if s[1] < 0.0:
        exit(1)
    if s[0] < s[1]:
        exit(1)

    # eig on a symmetric matrix: trace(A) = sum(eigenvalues), wi = 0
    a = reshape([2.0, 1.0, 1.0, 2.0], [2, 2])   # Eigenvalues are 1 and 3
    wr = zeros(2)
    wi = zeros(2)
    vr = reshape(zeros(4), [2, 2])
    eig(a, wr, wi, vr)
    trace = a[0, 0] + a[1, 1]
    sum_wr = wr[0] + wr[1]
    if abs(sum_wr - trace) > 1.0e-9:
        exit(1)
    if abs(wi[0]) > 1.0e-9:
        exit(1)
    if abs(wi[1]) > 1.0e-9:
        exit(1)

    print("test_linalg: all checks passed")

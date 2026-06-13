import support.sparse

def check_close(value: float, expected: float):
    if abs(value - expected) > 1.0e-9:
        exit(1)

def main():
    coo_data: array[float, :]
    coo_rows: array[int, :]
    coo_cols: array[int, :]
    csr: CSRMatrix
    csc: CSCMatrix
    factor: FactorizedResult
    rhs: array[float, :]
    x_serial: array[float, :]
    x_dc: array[float, :]
    x_co: array[float, :]
    x_cg: array[float, :]
    x_bicg: array[float, :]

    # Assemble a small matrix with a known sparsity pattern.
    coo_data = [10.0, 20.0, 30.0, 40.0]
    coo_rows = [0, 1, 1, 2]
    coo_cols = [0, 0, 2, 1]

    csr = csr_array(coo_data, coo_rows, coo_cols)
    if not (csr.num_rows == 3):
        exit(1)
    if not (csr.num_cols == 3):
        exit(1)
    if not (csr.indptr[0] == 0):
        exit(1)
    if not (csr.indptr[1] == 1):
        exit(1)
    if not (csr.indptr[2] == 3):
        exit(1)
    if not (csr.indptr[3] == 4):
        exit(1)
    if not (csr.indices[0] == 0):
        exit(1)
    if not (csr.indices[1] == 0):
        exit(1)
    if not (csr.indices[2] == 2):
        exit(1)
    if not (csr.indices[3] == 1):
        exit(1)
    check_close(csr.data[0], 10.0)
    check_close(csr.data[1], 20.0)
    check_close(csr.data[2], 30.0)
    check_close(csr.data[3], 40.0)

    csc = csr_to_csc(csr)
    if not (csc.indptr[0] == 0):
        exit(1)
    if not (csc.indptr[1] == 2):
        exit(1)
    if not (csc.indptr[2] == 3):
        exit(1)
    if not (csc.indptr[3] == 4):
        exit(1)
    if not (csc.indices[0] == 0):
        exit(1)
    if not (csc.indices[1] == 1):
        exit(1)
    if not (csc.indices[2] == 2):
        exit(1)
    if not (csc.indices[3] == 1):
        exit(1)
    check_close(csc.data[0], 10.0)
    check_close(csc.data[1], 20.0)
    check_close(csc.data[2], 40.0)
    check_close(csc.data[3], 30.0)

    # This system forces a pivot because A[0, 0] is zero.
    coo_data = [2.0, 1.0, 1.0, 1.0, 2.0, 3.0, 4.0]
    coo_rows = [0, 0, 1, 1, 2, 2, 2]
    coo_cols = [1, 2, 0, 1, 0, 1, 2]
    csr = csr_array(coo_data, coo_rows, coo_cols)
    csc = csr_to_csc(csr)
    factor = factorized(csc)

    rhs = [7.0, 3.0, 20.0]
    x_serial = solve(factor, rhs)
    x_dc = solve_dc(factor, rhs)

    check_close(x_serial[0], 1.0)
    check_close(x_serial[1], 2.0)
    check_close(x_serial[2], 3.0)
    check_close(x_dc[0], 1.0)
    check_close(x_dc[1], 2.0)
    check_close(x_dc[2], 3.0)

    # SPD tridiagonal system for Conjugate Gradient.
    coo_data = [4.0, -1.0, -1.0, 4.0, -1.0, -1.0, 3.0]
    coo_rows = [0, 0, 1, 1, 1, 2, 2]
    coo_cols = [0, 1, 0, 1, 2, 1, 2]
    csr = csr_array(coo_data, coo_rows, coo_cols)
    rhs = [15.0, 10.0, 10.0]
    x_cg = cg(csr, rhs, 1.0e-10, 64)

    check_close(x_cg[0], 5.0)
    check_close(x_cg[1], 5.0)
    check_close(x_cg[2], 5.0)

    # General nonsymmetric system for BiCGStab: A = [[4,1,0],[-1,5,2],[0,-1,3]], x = [1,2,3]
    coo_data = [4.0, 1.0, -1.0, 5.0, 2.0, -1.0, 3.0]
    coo_rows = [0, 0, 1, 1, 1, 2, 2]
    coo_cols = [0, 1, 0, 1, 2, 1, 2]
    csr = csr_array(coo_data, coo_rows, coo_cols)
    rhs = [6.0, 15.0, 7.0]
    x_bicg = bicgstab(csr, rhs, 1.0e-10, 64)

    check_close(x_bicg[0], 1.0)
    check_close(x_bicg[1], 2.0)
    check_close(x_bicg[2], 3.0)

    print("test_sparse: all checks passed")

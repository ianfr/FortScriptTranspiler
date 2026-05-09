# Showcase for support.sparse: CSR/CSC construction, LU direct solve (serial
# and parallel), spmv_csr, and the CG iterative solver.
#
# Applied problems used:
#   1. 1D Poisson BVP u''(x) = f(x) on [0, 1] with Dirichlet BCs (direct LU).
#   2. Same 1D Poisson system solved again with CG to verify consistency.
#   3. Matrix-vector product on a 1D advection stencil (spmv_csr).
#   4. solve_dc demonstrated on the same Poisson system as solve.

import support.sparse


# Build the (n-1) x (n-1) interior tridiagonal stiffness matrix for the
# 1D Poisson problem -u'' = f on [0,1] with u(0)=u(1)=0.
# The standard 3-point stencil gives A_ii = 2/h^2, A_{i,i+-1} = -1/h^2.
# Returns a CSRMatrix.
def build_poisson_1d(n: int) -> CSRMatrix:
    h: float = 0.0               # Grid spacing h = 1/n.
    m: int = 0                   # Interior degrees of freedom = n - 1.
    nnz: int = 0                 # Total nonzeros: m diag + (m-1) + (m-1) off-diag.
    idx: int = 0                 # Running insertion index for COO triplets.
    i: int = 0
    diag_val: float = 0.0
    off_val: float = 0.0
    data: array[float, :]
    row_ind: array[int, :]
    col_ind: array[int, :]

    h = 1.0 / n
    m = n - 1
    nnz = 3 * m - 2              # One diagonal per row, two off-diagonals for interior rows.
    diag_val = 2.0 / (h * h)
    off_val = -1.0 / (h * h)

    allocate(data, nnz)
    allocate(row_ind, nnz)
    allocate(col_ind, nnz)

    idx = 0
    for i in range(m):
        data[idx] = diag_val     # Diagonal entry.
        row_ind[idx] = i
        col_ind[idx] = i
        idx += 1
        if i > 0:                # Sub-diagonal.
            data[idx] = off_val
            row_ind[idx] = i
            col_ind[idx] = i - 1
            idx += 1
        if i < m - 1:            # Super-diagonal.
            data[idx] = off_val
            row_ind[idx] = i
            col_ind[idx] = i + 1
            idx += 1

    return csr_array(data, row_ind, col_ind)


# Compute the RHS vector for -u'' = pi^2 * sin(pi*x) so the exact solution
# is u(x) = sin(pi*x).  Evaluates at interior grid points x_i = i*h.
def build_rhs_poisson(n: int) -> array[float, :]:
    h: float = 0.0
    m: int = 0
    i: int = 0
    b: array[float, :]

    h = 1.0 / n
    m = n - 1
    allocate(b, m)
    for i in range(m):
        b[i] = 3.14159265358979 * 3.14159265358979 * sin(3.14159265358979 * (i + 1) * h)

    return b


# Demo 1: direct LU solve (serial) for 1D Poisson.
# Exercises: csr_to_csc, factorized, solve.
def demo_lu_serial():
    n: int = 8                   # Number of sub-intervals (8 gives 7 interior nodes).
    m: int = 0
    i: int = 0
    h: float = 0.0
    max_err: float = 0.0
    err: float = 0.0
    A_csr: CSRMatrix
    A_csc: CSCMatrix
    fac: FactorizedResult
    b: array[float, :]
    x: array[float, :]
    u_exact: float = 0.0

    m = n - 1
    h = 1.0 / n

    A_csr = build_poisson_1d(n)
    A_csc = csr_to_csc(A_csr)   # LU factorization requires CSC input.
    fac = factorized(A_csc)
    b = build_rhs_poisson(n)
    x = solve(fac, b)

    max_err = 0.0
    for i in range(m):
        u_exact = sin(3.14159265358979 * (i + 1) * h)
        err = abs(x[i] - u_exact)
        if err > max_err:
            max_err = err

    print("demo_lu_serial: 1D Poisson n=8, max error vs sin(pi*x):", max_err)


# Demo 2: parallel LU solve (solve_dc) for 1D Poisson.
# Exercises: solve_dc with the same FactorizedResult produced in demo_lu_serial.
def demo_lu_dc():
    n: int = 8
    m: int = 0
    i: int = 0
    h: float = 0.0
    max_err: float = 0.0
    err: float = 0.0
    A_csr: CSRMatrix
    A_csc: CSCMatrix
    fac: FactorizedResult
    b: array[float, :]
    x: array[float, :]
    u_exact: float = 0.0

    m = n - 1
    h = 1.0 / n

    A_csr = build_poisson_1d(n)
    A_csc = csr_to_csc(A_csr)
    fac = factorized(A_csc)
    b = build_rhs_poisson(n)
    x = solve_dc(fac, b)         # Parallel inner sweeps via do concurrent.

    max_err = 0.0
    for i in range(m):
        u_exact = sin(3.14159265358979 * (i + 1) * h)
        err = abs(x[i] - u_exact)
        if err > max_err:
            max_err = err

    print("demo_lu_dc:     1D Poisson n=8, max error vs sin(pi*x):", max_err)


# Demo 3: CG iterative solver for 1D Poisson.
# The Poisson stiffness matrix is SPD so CG is applicable.
# Exercises: cg with tolerances tighter than the discretisation error.
def demo_cg():
    n: int = 32                  # Larger grid to show CG scaling.
    m: int = 0
    i: int = 0
    h: float = 0.0
    max_err: float = 0.0
    err: float = 0.0
    A_csr: CSRMatrix
    b: array[float, :]
    x: array[float, :]
    u_exact: float = 0.0

    m = n - 1
    h = 1.0 / n

    A_csr = build_poisson_1d(n)
    b = build_rhs_poisson(n)
    x = cg(A_csr, b, 1.0e-10, 1000)  # Tight relative tolerance; CSR input, no factorization needed.

    max_err = 0.0
    for i in range(m):
        u_exact = sin(3.14159265358979 * (i + 1) * h)
        err = abs(x[i] - u_exact)
        if err > max_err:
            max_err = err

    print("demo_cg:        1D Poisson n=32, max error vs sin(pi*x):", max_err)


# Demo 4: sparse matrix-vector product with spmv_csr.
# Applies the 1D upwind advection matrix (shift-left by one) to a sine wave
# and checks that the result is the expected shifted vector.
# Stencil: (A x)_i = x_{i+1} - x_i (forward-difference advection).
def demo_spmv():
    n: int = 8                   # Number of sub-intervals; m = n-1 interior nodes.
    m: int = 0
    h: float = 0.0
    i: int = 0
    nnz: int = 0
    idx: int = 0
    data: array[float, :]
    row_ind: array[int, :]
    col_ind: array[int, :]
    A_adv: CSRMatrix
    v_in: array[float, :]        # Input sine wave evaluated on interior nodes.
    v_out: array[float, :]       # Result of A * v_in.
    ref: float = 0.0             # Expected entry computed directly.
    max_err: float = 0.0
    err: float = 0.0

    m = n - 1
    h = 1.0 / n

    # Build upwind advection matrix: diagonal -1, super-diagonal +1.
    # Last row has only the diagonal (open boundary at the right end).
    nnz = 2 * m - 1
    allocate(data, nnz)
    allocate(row_ind, nnz)
    allocate(col_ind, nnz)

    idx = 0
    for i in range(m):
        data[idx] = -1.0
        row_ind[idx] = i
        col_ind[idx] = i
        idx += 1
        if i < m - 1:
            data[idx] = 1.0
            row_ind[idx] = i
            col_ind[idx] = i + 1
            idx += 1

    A_adv = csr_array(data, row_ind, col_ind)

    # Input vector: v_i = sin(pi * x_i).
    allocate(v_in, m)
    for i in range(m):
        v_in[i] = sin(3.14159265358979 * (i + 1) * h)

    v_out = spmv_csr(A_adv, v_in)

    # Reference: (Av)_i = v_{i+1} - v_i for interior rows.
    max_err = 0.0
    for i in range(m - 1):
        ref = v_in[i + 1] - v_in[i]
        err = abs(v_out[i] - ref)
        if err > max_err:
            max_err = err

    print("demo_spmv:      1D advection spmv max error:", max_err)


# Demo 5: multi-RHS direct LU reuse.
# The same factorization is applied to two different right-hand sides to
# illustrate that factorized() is called once and solve() is called twice.
def demo_lu_multi_rhs():
    n: int = 8
    m: int = 0
    h: float = 0.0
    i: int = 0
    A_csr: CSRMatrix
    A_csc: CSCMatrix
    fac: FactorizedResult
    b1: array[float, :]          # RHS 1: pi^2 sin(pi x) -> exact solution sin(pi x).
    b2: array[float, :]          # RHS 2: uniform load f=1 -> exact u = x(1-x)/2.
    x1: array[float, :]
    x2: array[float, :]
    err1: float = 0.0
    err2: float = 0.0
    u_exact1: float = 0.0
    u_exact2: float = 0.0
    max_err1: float = 0.0
    max_err2: float = 0.0

    m = n - 1
    h = 1.0 / n

    A_csr = build_poisson_1d(n)
    A_csc = csr_to_csc(A_csr)
    fac = factorized(A_csc)      # Factor once.

    b1 = build_rhs_poisson(n)    # Sine load.

    allocate(b2, m)              # Uniform unit load.
    for i in range(m):
        b2[i] = 1.0

    x1 = solve(fac, b1)          # First solve.
    x2 = solve(fac, b2)          # Second solve, same factorization.

    max_err1 = 0.0
    max_err2 = 0.0
    for i in range(m):
        u_exact1 = sin(3.14159265358979 * (i + 1) * h)
        err1 = abs(x1[i] - u_exact1)
        if err1 > max_err1:
            max_err1 = err1

        u_exact2 = (i + 1) * h * (1.0 - (i + 1) * h) / 2.0
        err2 = abs(x2[i] - u_exact2)
        if err2 > max_err2:
            max_err2 = err2

    print("demo_lu_multi_rhs: sine RHS max error:", max_err1)
    print("demo_lu_multi_rhs: uniform RHS max error:", max_err2)


def main():
    demo_lu_serial()
    demo_lu_dc()
    demo_cg()
    demo_spmv()
    demo_lu_multi_rhs()

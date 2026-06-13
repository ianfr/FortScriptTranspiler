# FortScript sparse support library, itself written completely in FortScript
# Contains:
#   - Sparse matrix classes: CSR and CSC
#   - Sparse LU decomposition with partial pivoting (PA = LU)
#   - Solvers:
#       - solve (serial direct via pre-factored LU)
#       - solve_dc (do concurrent accelerated direct via pre-factored LU)
#       - cg (do concurrent accelerated Conjugate Gradient, SPD only)
#       - bicgstab (do concurrent accelerated stabilized biconjugate gradient,
#         general nonsymmetric matrices)

# Design notes:
#   - CSC storage matches Fortran's column-major memory order so that every
#     column scan of L or U walks a contiguous block of memory.
#   - The factorization never materializes a dense n*n copy of the input.
#     It keeps one length-n dense scratch column while emitting L and U
#     straight back into CSC arrays.

struct CSRMatrix:
    data: array[float, :]       # Nonzero values in row-major order.
    indices: array[int, :]      # Column index of each nonzero.
    indptr: array[int, :]       # Row offsets; row i spans [indptr[i], indptr[i+1]).
    num_rows: int
    num_cols: int

struct CSCMatrix:
    data: array[float, :]       # Column-contiguous nonzero values (Fortran-friendly storage).
    indices: array[int, :]      # Row index of each nonzero.
    indptr: array[int, :]       # Column offsets; column j spans [indptr[j], indptr[j+1]).
    num_rows: int
    num_cols: int

# Factorized LU with partial (row) pivoting such that P*A = L*U.
struct FactorizedResult:
    L: CSCMatrix                # Unit lower triangular factor; diagonal 1s stored explicitly first per column.
    U: CSCMatrix                # Upper triangular factor; diagonal pivot stored explicitly last per column.
    perm: array[int, :]         # Row permutation: perm[i] is the original A-row at logical row i.


# Constructor for CSR matrix class.
# Mirrors scipy.sparse.csr_array((data, (row_ind, col_ind))):
#   "data, row_ind and col_ind satisfy the relationship a[row_ind[k], col_ind[k]] = data[k]."
# See https://docs.scipy.org/doc/scipy/reference/generated/scipy.sparse.csr_array.html#scipy.sparse.csr_array
def csr_array(data: array[float, :], row_ind: array[int, :], col_ind: array[int, :]) -> CSRMatrix:
    result: CSRMatrix
    nnz: int = 0                # Number of input triplets.
    n_rows: int = 0             # Inferred row count (max row index + 1).
    n_cols: int = 0             # Inferred column count.
    i: int = 0
    r: int = 0
    dest: int = 0
    counts: array[int, :]       # Per-row nonzero counts, used to build indptr.
    offsets: array[int, :]      # Running insertion offsets per row during scatter.
    out_data: array[float, :]
    out_indices: array[int, :]
    out_indptr: array[int, :]

    # Infer matrix shape from the largest index seen in the triplets.
    nnz = size(data)
    for i in range(nnz):
        if row_ind[i] + 1 > n_rows:
            n_rows = row_ind[i] + 1
        if col_ind[i] + 1 > n_cols:
            n_cols = col_ind[i] + 1

    # Bucket each triplet by row so indptr is a simple prefix sum.
    allocate(counts, n_rows)
    for i in range(n_rows):
        counts[i] = 0
    for i in range(nnz):
        counts[row_ind[i]] += 1

    allocate(out_indptr, n_rows + 1)
    out_indptr[0] = 0
    for i in range(n_rows):
        out_indptr[i + 1] = out_indptr[i] + counts[i]

    # Scatter triplets into their destination slots in input order within each row.
    allocate(offsets, n_rows)
    for i in range(n_rows):
        offsets[i] = 0
    allocate(out_data, nnz)
    allocate(out_indices, nnz)
    for i in range(nnz):
        r = row_ind[i]
        dest = out_indptr[r] + offsets[r]
        out_data[dest] = data[i]
        out_indices[dest] = col_ind[i]
        offsets[r] += 1

    result.data = out_data
    result.indices = out_indices
    result.indptr = out_indptr
    result.num_rows = n_rows
    result.num_cols = n_cols
    return result


# Transpose-like conversion from CSR to CSC; preserves sorted row indices inside each CSC column.
def csr_to_csc(A: CSRMatrix) -> CSCMatrix:
    result: CSCMatrix
    nnz: int = 0
    n_rows: int = 0
    n_cols: int = 0
    i: int = 0
    p: int = 0
    c: int = 0
    dest: int = 0
    counts: array[int, :]       # Per-column counts for building the CSC indptr.
    offsets: array[int, :]      # Running per-column insertion offsets during scatter.
    out_data: array[float, :]
    out_indices: array[int, :]
    out_indptr: array[int, :]

    n_rows = A.num_rows
    n_cols = A.num_cols
    nnz = size(A.data)

    # Count how many entries land in each column via a single pass over CSR indices.
    allocate(counts, n_cols)
    for i in range(n_cols):
        counts[i] = 0
    for i in range(nnz):
        counts[A.indices[i]] += 1

    allocate(out_indptr, n_cols + 1)
    out_indptr[0] = 0
    for i in range(n_cols):
        out_indptr[i + 1] = out_indptr[i] + counts[i]

    # Walking CSR rows in order guarantees the resulting CSC rows stay sorted.
    allocate(offsets, n_cols)
    for i in range(n_cols):
        offsets[i] = 0
    allocate(out_data, nnz)
    allocate(out_indices, nnz)
    for i in range(n_rows):
        for p in range(A.indptr[i], A.indptr[i + 1]):
            c = A.indices[p]
            dest = out_indptr[c] + offsets[c]
            out_data[dest] = A.data[p]
            out_indices[dest] = i
            offsets[c] += 1

    result.data = out_data
    result.indices = out_indices
    result.indptr = out_indptr
    result.num_rows = n_rows
    result.num_cols = n_cols
    return result


# PA = LU factorization with partial pivoting.
# Mirrors the direct-factor path of https://docs.scipy.org/doc/scipy/reference/generated/scipy.sparse.linalg.factorized.html
# (the result is reused across solves, so the factor cost is paid once).
# Algorithmic outline (left-looking, one CSC column at a time):
#   1. Scatter column k of A into a dense length-n work vector, mapping original
#      rows to logical rows through the current permutation.
#   2. Apply already-factored L columns 0..k-1 via sparse forward substitution.
#   3. Choose the largest-magnitude entry at logical row >= k as the pivot.
#      If that row is not row k, swap logical rows k and pivot_row in the
#      permutation and in the row indices stored inside existing L columns.
#   4. Emit U column k (rows 0..k, diagonal last) and L column k (diagonal 1
#      first, then rows k+1..n-1 divided by the pivot) into the CSC arrays.
# L and U remain in CSC throughout so every write is sequential in memory.
def factorized(A: CSCMatrix) -> FactorizedResult:
    result: FactorizedResult
    n: int = 0
    nnz_A: int = 0
    max_nnz: int = 0
    i: int = 0
    j: int = 0
    k: int = 0
    p: int = 0
    col_start: int = 0
    col_end: int = 0
    row: int = 0
    pivot_row: int = 0
    pivot_val: float = 0.0
    abs_val: float = 0.0
    tmp_int: int = 0
    tmp_float: float = 0.0

    x: array[float, :]          # Dense scratch column (length n) reused across steps.
    perm: array[int, :]         # perm[i] = original A-row now occupying logical row i.
    inv_perm: array[int, :]     # inv_perm[orig_row] = current logical row for that original row.

    L_data: array[float, :]     # CSC storage for L (column-major, Fortran-friendly).
    L_indices: array[int, :]
    L_indptr: array[int, :]
    L_nnz: int = 0

    U_data: array[float, :]     # CSC storage for U (column-major, Fortran-friendly).
    U_indices: array[int, :]
    U_indptr: array[int, :]
    U_nnz: int = 0

    L_final_data: array[float, :]   # Tight copies of the sparse arrays sized to the real nnz.
    L_final_indices: array[int, :]
    U_final_data: array[float, :]
    U_final_indices: array[int, :]

    n = A.num_cols
    nnz_A = size(A.data)

    # Safe upper bound: a dense triangle is the worst case for either factor.
    # For very large and very sparse problems a symbolic pre-pass would be
    # preferable, but this keeps the bootstrap implementation simple.
    max_nnz = (n * (n + 1)) / 2
    if max_nnz < nnz_A + n:
        max_nnz = nnz_A + n

    allocate(x, n)
    allocate(perm, n)
    allocate(inv_perm, n)
    allocate(L_data, max_nnz)
    allocate(L_indices, max_nnz)
    allocate(L_indptr, n + 1)
    allocate(U_data, max_nnz)
    allocate(U_indices, max_nnz)
    allocate(U_indptr, n + 1)

    # Start with the identity permutation.
    for i in range(n):
        perm[i] = i
        inv_perm[i] = i

    L_nnz = 0
    U_nnz = 0
    L_indptr[0] = 0
    U_indptr[0] = 0

    # Factor one column of A per outer iteration (left-looking Gilbert-Peierls).
    for k in range(n):
        # Zero the dense column scratch.
        for i in range(n):
            x[i] = 0.0

        # Scatter column k of A, translating original rows to logical rows.
        col_start = A.indptr[k]
        col_end = A.indptr[k + 1]
        for p in range(col_start, col_end):
            row = A.indices[p]
            x[inv_perm[row]] = A.data[p]

        # Apply previously factored L columns (sparse forward substitution).
        # L[j, j] = 1 is stored first in column j so we iterate with row > j to skip it.
        for j in range(k):
            if x[j] != 0.0:
                for p in range(L_indptr[j], L_indptr[j + 1]):
                    row = L_indices[p]
                    if row > j:
                        x[row] -= x[j] * L_data[p]

        # Partial pivoting: pick the largest-magnitude row at or below logical row k.
        pivot_row = k
        pivot_val = abs(x[k])
        for i in range(k + 1, n):
            abs_val = abs(x[i])
            if abs_val > pivot_val:
                pivot_val = abs_val
                pivot_row = i

        if pivot_row != k:
            # Swap entries k and pivot_row in the current dense column.
            tmp_float = x[k]
            x[k] = x[pivot_row]
            x[pivot_row] = tmp_float

            # Keep perm and its inverse consistent with the logical row swap.
            tmp_int = perm[k]
            perm[k] = perm[pivot_row]
            perm[pivot_row] = tmp_int
            inv_perm[perm[k]] = k
            inv_perm[perm[pivot_row]] = pivot_row

            # Re-label already-stored L rows so future reads see consistent logical rows.
            # This is O(nnz(L_so_far)) per pivot but avoids ever touching a dense matrix.
            for j in range(k):
                for p in range(L_indptr[j], L_indptr[j + 1]):
                    if L_indices[p] == k:
                        L_indices[p] = pivot_row
                    elif L_indices[p] == pivot_row:
                        L_indices[p] = k

        # Emit column k of U: rows 0..k-1 in order, pivot stored last so back-substitution
        # can read it in O(1) from indptr[k+1] - 1.
        U_indptr[k] = U_nnz
        for i in range(k):
            if x[i] != 0.0:
                U_data[U_nnz] = x[i]
                U_indices[U_nnz] = i
                U_nnz += 1
        U_data[U_nnz] = x[k]
        U_indices[U_nnz] = k
        U_nnz += 1
        U_indptr[k + 1] = U_nnz

        # Emit column k of L: unit diagonal first, scaled below-diagonal entries next.
        L_indptr[k] = L_nnz
        L_data[L_nnz] = 1.0
        L_indices[L_nnz] = k
        L_nnz += 1
        for i in range(k + 1, n):
            if x[i] != 0.0:
                L_data[L_nnz] = x[i] / x[k]
                L_indices[L_nnz] = i
                L_nnz += 1
        L_indptr[k + 1] = L_nnz

    # Trim over-allocated scratch arrays down to the actual nnz counts.
    allocate(L_final_data, L_nnz)
    allocate(L_final_indices, L_nnz)
    for i in range(L_nnz):
        L_final_data[i] = L_data[i]
        L_final_indices[i] = L_indices[i]

    allocate(U_final_data, U_nnz)
    allocate(U_final_indices, U_nnz)
    for i in range(U_nnz):
        U_final_data[i] = U_data[i]
        U_final_indices[i] = U_indices[i]

    result.L.data = L_final_data
    result.L.indices = L_final_indices
    result.L.indptr = L_indptr
    result.L.num_rows = n
    result.L.num_cols = n
    result.U.data = U_final_data
    result.U.indices = U_final_indices
    result.U.indptr = U_indptr
    result.U.num_rows = n
    result.U.num_cols = n
    result.perm = perm
    return result


# Serial sparse solve: given a pre-factored LU, solve A x = b.
# Steps: apply P to b, sparse forward-sub with L (diagonal first), sparse back-sub
# with U (diagonal last). Both sweeps walk CSC columns contiguously in memory.
def solve(A_fac: FactorizedResult, b: array[float, :]) -> array[float, :]:
    n: int = 0
    i: int = 0
    j: int = 0
    p: int = 0
    diag_p: int = 0
    col_start: int = 0
    col_end: int = 0
    pivot_val: float = 0.0
    y: array[float, :]

    n = A_fac.L.num_cols

    # y = P * b (apply row permutation in place into a fresh buffer).
    allocate(y, n)
    for i in range(n):
        y[i] = b[A_fac.perm[i]]

    # Forward substitution through L (unit diagonal at position indptr[j], so skip it).
    for j in range(n):
        pivot_val = y[j]
        col_start = A_fac.L.indptr[j] + 1
        col_end = A_fac.L.indptr[j + 1]
        for p in range(col_start, col_end):
            y[A_fac.L.indices[p]] -= pivot_val * A_fac.L.data[p]

    # Back substitution through U (diagonal at position indptr[j+1] - 1).
    for i in range(n):
        j = n - 1 - i              # Walk columns n-1, n-2, ..., 0.
        diag_p = A_fac.U.indptr[j + 1] - 1
        y[j] = y[j] / A_fac.U.data[diag_p]
        pivot_val = y[j]
        for p in range(A_fac.U.indptr[j], diag_p):
            y[A_fac.U.indices[p]] -= pivot_val * A_fac.U.data[p]

    return y


# Do concurrent accelerated sparse solve.
# Same algorithm as solve(), but the inner column sweeps are @par because each
# column of L (and of U) has unique row indices, so the scatter-updates within
# a single column are independent. The outer j loop stays serial because of
# the inherent triangular-solve dependency.
def solve_dc(A_fac: FactorizedResult, b: array[float, :]) -> array[float, :]:
    n: int = 0
    i: int = 0
    j: int = 0
    p: int = 0
    diag_p: int = 0
    col_start: int = 0
    col_end: int = 0
    pivot_val: float = 0.0
    y: array[float, :]

    n = A_fac.L.num_cols

    allocate(y, n)
    for i in range(n):
        y[i] = b[A_fac.perm[i]]

    # Forward substitution with the inner sweep parallelized.
    for j in range(n):
        pivot_val = y[j]
        col_start = A_fac.L.indptr[j] + 1
        col_end = A_fac.L.indptr[j + 1]
        @par
        for p in range(col_start, col_end):
            y[A_fac.L.indices[p]] -= pivot_val * A_fac.L.data[p]

    # Back substitution with the inner sweep parallelized.
    for i in range(n):
        j = n - 1 - i
        diag_p = A_fac.U.indptr[j + 1] - 1
        y[j] = y[j] / A_fac.U.data[diag_p]
        pivot_val = y[j]
        @par
        for p in range(A_fac.U.indptr[j], diag_p):
            y[A_fac.U.indices[p]] -= pivot_val * A_fac.U.data[p]

    return y


# Parallel sparse matrix-vector product y = A * x for CSR storage.
# Every output row is independent, so the outer sweep runs under @par.
# The inner cursor p is nested and therefore picked up as LOCAL automatically;
# writing y[i] directly avoids needing a LOCAL scalar accumulator.
def spmv_csr(A: CSRMatrix, x: array[float, :]) -> array[float, :]:
    y: array[float, :]           # Output vector (length num_rows).
    i: int = 0
    p: int = 0
    n_rows: int = 0

    n_rows = A.num_rows
    allocate(y, n_rows)

    @par
    for i in range(n_rows):
        y[i] = 0.0
        for p in range(A.indptr[i], A.indptr[i + 1]):
            y[i] = y[i] + A.data[p] * x[A.indices[p]]

    return y

# https://en.wikipedia.org/wiki/Conjugate_gradient_method#The_resulting_algorithm
# Conjugate Gradient iterative solver for A x = b.
# Assumes A is symmetric positive definite (e.g. the negated discrete Laplacian
# for a Poisson problem). Starts from x = 0 and terminates when
# ||r||^2 < tol^2 * ||b||^2 or after max_iter iterations (whichever first).
# Parallelism: spmv is @par row-wise; AXPY sweeps are @par; dot products use
# @par with @reduce(add: ...). The outer CG iteration stays serial due to its
# inherent sequential dependency between updates.
def cg(A: CSRMatrix, b: array[float, :], tol: float, max_iter: int) -> array[float, :]:
    n: int = 0
    i: int = 0
    it: int = 0
    x: array[float, :]           # Current iterate (solution estimate).
    r: array[float, :]           # Residual r = b - A x.
    p: array[float, :]           # Search direction.
    Ap: array[float, :]          # Matrix times current search direction.
    rs_old: float = 0.0          # r^T r from the previous iteration.
    rs_new: float = 0.0          # r^T r after the AXPY updates this iteration.
    alpha: float = 0.0
    beta: float = 0.0
    pAp: float = 0.0             # p^T A p (curvature along the search direction).
    bnorm_sq: float = 0.0        # ||b||^2, cached for the relative-tolerance test.

    n = A.num_rows
    allocate(x, n)
    allocate(r, n)
    allocate(p, n)

    # Initialize x = 0, r = b, p = b.
    @par
    for i in range(n):
        x[i] = 0.0
        r[i] = b[i]
        p[i] = b[i]

    # Precompute ||b||^2 for the relative stopping test.
    @par
    @reduce(add: bnorm_sq)
    for i in range(n):
        bnorm_sq = bnorm_sq + b[i] * b[i]

    # Degenerate zero-RHS: the zero vector already solves the system.
    if bnorm_sq == 0.0:
        return x

    rs_old = bnorm_sq

    for it in range(max_iter):
        Ap = spmv_csr(A, p)

        # Curvature pAp = p . A p for the step-length formula.
        pAp = 0.0
        @par
        @reduce(add: pAp)
        for i in range(n):
            pAp = pAp + p[i] * Ap[i]

        # Guard the step-length update against CG breakdown before dividing.
        if pAp == 0.0 or pAp != pAp:
            return x

        alpha = rs_old / pAp

        # Update the iterate and the residual in a single parallel sweep.
        @par
        for i in range(n):
            x[i] = x[i] + alpha * p[i]
            r[i] = r[i] - alpha * Ap[i]

        # Fresh residual norm (squared) drives convergence and beta.
        rs_new = 0.0
        @par
        @reduce(add: rs_new)
        for i in range(n):
            rs_new = rs_new + r[i] * r[i]

        # Residual NaN indicates the solve has broken down numerically.
        if rs_new != rs_new:
            return x

        if rs_new < tol * tol * bnorm_sq:
            return x

        beta = rs_new / rs_old

        # New search direction blends the residual with the old direction.
        @par
        for i in range(n):
            p[i] = r[i] + beta * p[i]

        rs_old = rs_new

    return x

# https://en.wikipedia.org/wiki/Biconjugate_gradient_stabilized_method#Unpreconditioned_BiCGSTAB
# Stabilized biconjugate gradient solver for A x = b on general nonsymmetric
# matrices. Starts from x = 0. Terminates when ||r||^2 < tol^2 * ||b||^2 or
# after max_iter iterations. spmv, AXPY, and dot kernels run under @par; the
# outer iteration stays serial. Returns the current iterate early on numerical
# breakdown (rho, alpha, or omega becomes zero or NaN) so callers can fall back
# to a more robust path without crashing.
def bicgstab(A: CSRMatrix, b: array[float, :], tol: float, max_iter: int) -> array[float, :]:
    n: int = 0
    i: int = 0
    it: int = 0
    x: array[float, :]               # Current iterate.
    r: array[float, :]               # Residual r = b - A x.
    r_hat: array[float, :]           # Shadow residual, frozen at the start.
    p: array[float, :]               # Search direction.
    v: array[float, :]               # A p.
    s: array[float, :]               # Intermediate residual after the alpha step.
    t: array[float, :]               # A s.
    rho_old: float = 1.0
    rho_new: float = 0.0
    alpha: float = 1.0
    omega: float = 1.0
    beta: float = 0.0
    rhat_v: float = 0.0              # dot(r_hat, v) for the alpha update.
    ts: float = 0.0                  # dot(t, s) for the omega update.
    tt: float = 0.0                  # dot(t, t) for the omega update.
    rs_new: float = 0.0              # ||r||^2 for the convergence test.
    s_norm_sq: float = 0.0           # ||s||^2 for the early-exit test after the alpha step.
    bnorm_sq: float = 0.0            # ||b||^2 cached for relative tolerance.

    n = A.num_rows
    allocate(x, n)
    allocate(r, n)
    allocate(r_hat, n)
    allocate(p, n)
    allocate(v, n)
    allocate(s, n)

    # Initialise x = 0, r = b, r_hat = b, p = 0, v = 0.
    @par
    for i in range(n):
        x[i] = 0.0
        r[i] = b[i]
        r_hat[i] = b[i]
        p[i] = 0.0
        v[i] = 0.0

    # Precompute ||b||^2 for the relative stopping test.
    @par
    @reduce(add: bnorm_sq)
    for i in range(n):
        bnorm_sq = bnorm_sq + b[i] * b[i]

    # Degenerate zero-RHS: the zero vector already solves the system.
    if bnorm_sq == 0.0:
        return x

    for it in range(max_iter):
        # rho_new = dot(r_hat, r).
        rho_new = 0.0
        @par
        @reduce(add: rho_new)
        for i in range(n):
            rho_new = rho_new + r_hat[i] * r[i]

        # Breakdown if rho collapses; return the best iterate so far.
        if rho_new == 0.0 or rho_new != rho_new:
            return x

        # p = r + beta * (p - omega * v); for the first iteration beta drops out.
        if it == 0:
            @par
            for i in range(n):
                p[i] = r[i]
        else:
            beta = (rho_new / rho_old) * (alpha / omega)
            @par
            for i in range(n):
                p[i] = r[i] + beta * (p[i] - omega * v[i])

        v = spmv_csr(A, p)

        # alpha = rho_new / dot(r_hat, v).
        rhat_v = 0.0
        @par
        @reduce(add: rhat_v)
        for i in range(n):
            rhat_v = rhat_v + r_hat[i] * v[i]

        if rhat_v == 0.0 or rhat_v != rhat_v:
            return x

        alpha = rho_new / rhat_v

        # s = r - alpha v.
        @par
        for i in range(n):
            s[i] = r[i] - alpha * v[i]

        # Early exit: if s is already tiny, the alpha step alone is enough.
        s_norm_sq = 0.0
        @par
        @reduce(add: s_norm_sq)
        for i in range(n):
            s_norm_sq = s_norm_sq + s[i] * s[i]

        if s_norm_sq < tol * tol * bnorm_sq:
            @par
            for i in range(n):
                x[i] = x[i] + alpha * p[i]
            return x

        t = spmv_csr(A, s)

        # omega = dot(t, s) / dot(t, t).
        ts = 0.0
        tt = 0.0
        @par
        @reduce(add: ts)
        for i in range(n):
            ts = ts + t[i] * s[i]
        @par
        @reduce(add: tt)
        for i in range(n):
            tt = tt + t[i] * t[i]

        if tt == 0.0 or tt != tt:
            return x

        omega = ts / tt

        if omega == 0.0 or omega != omega:
            return x

        # x += alpha p + omega s; r = s - omega t.
        @par
        for i in range(n):
            x[i] = x[i] + alpha * p[i] + omega * s[i]
            r[i] = s[i] - omega * t[i]

        # Convergence test on the new residual norm.
        rs_new = 0.0
        @par
        @reduce(add: rs_new)
        for i in range(n):
            rs_new = rs_new + r[i] * r[i]

        if rs_new != rs_new:
            return x

        if rs_new < tol * tol * bnorm_sq:
            return x

        rho_old = rho_new

    return x

# do concurrent FortScript port of benchmarks/laplace_2d.py.
# The interior stencil, copy, and norm loops are marked with @par.
# Loop order: outer over columns (i), inner over rows (j) for column-major locality.

def laplace_2d(nx: int, ny: int, rtol: float, maxiter: int):
    # Domain bounds
    xmin: float = 0.0
    xmax: float = 2.0
    ymin: float = 0.0
    ymax: float = 1.0

    # Grid spacing
    dx: float = (xmax - xmin) / (nx - 1)
    dy: float = (ymax - ymin) / (ny - 1)

    # Precompute stencil coefficients
    dx2: float = dx * dx
    dy2: float = dy * dy
    denom: float = 2.0 * (dx2 + dy2)

    # Allocate grids
    phi: array[float, :, :]   # Solution grid (ny x nx)
    pn: array[float, :, :]    # Previous iterate
    y: array[float, :]        # y-axis coordinates for BC

    allocate(phi, ny, nx)
    allocate(pn, ny, nx)
    allocate(y, ny)

    # Build y coordinate vector
    for j in range(ny):
        y[j] = ymin + j * dy  # Uniform spacing

    # Initialize phi to ones
    @par
    for i in range(nx):
        for j in range(ny):
            phi[j, i] = 1.0  # Flat initial guess

    l1norm: float = 2.0 * rtol  # Ensure at least one iteration
    niter: int = 0
    sum_err: float = 0.0  # Numerator of relative norm
    sum_abs: float = 0.0  # Denominator of relative norm

    # Jacobi iteration
    while l1norm > rtol:
        if niter >= maxiter:
            pass  # Bail out at the iteration cap.
        else:
            # Copy phi into pn (parallel)
            @par
            for i in range(nx):
                for j in range(ny):
                    pn[j, i] = phi[j, i]  # Snapshot current iterate.

            # Update interior points with 5-point stencil (parallel over columns)
            @par
            for i in range(1, nx - 1):
                for j in range(1, ny - 1):
                    phi[j, i] = (dy2 * (pn[j, i + 1] + pn[j, i - 1]) + dx2 * (pn[j + 1, i] + pn[j - 1, i])) / denom  # Jacobi stencil

            # Apply boundary conditions
            for j in range(ny):
                phi[j, 0] = 0.0  # phi = 0 at x = xmin

            for j in range(ny):
                phi[j, nx - 1] = y[j]  # phi = y at x = xmax

            for i in range(nx):
                phi[0, i] = phi[1, i]  # dphi/dy = 0 at y = ymin

            for i in range(nx):
                phi[ny - 1, i] = phi[ny - 2, i]  # dphi/dy = 0 at y = ymax

            # Compute relative L1 norm (parallel reduction)
            sum_err = 0.0
            sum_abs = 0.0
            @par
            @reduce(add: sum_err)
            @reduce(add: sum_abs)
            for i in range(nx):
                for j in range(ny):
                    sum_err += abs(phi[j, i] - pn[j, i])  # Absolute difference
                    sum_abs += abs(pn[j, i])  # Reference magnitude

            l1norm = sum_err / sum_abs  # Relative convergence measure
            niter += 1

    # Compute sum(phi) as a verification check (parallel reduction)
    sum_phi: float = 0.0
    @par
    @reduce(add: sum_phi)
    for i in range(nx):
        for j in range(ny):
            sum_phi += phi[j, i]  # Accumulate the solution.

    print("sum(phi):", sum_phi)
    print("niter:", niter)

def main():
    laplace_2d(5000, 5000, 1e-6, 5000)  # Match the Python benchmark inputs.

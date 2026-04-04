# Coarray FortScript port of benchmarks/laplace_2d.py.
# Each image owns a horizontal band of rows and exchanges ghost rows via coarrays.
# The domain is [0,2] x [0,1] with nx columns and ny rows total.
# Loop order: outer over columns (i), inner over rows (jj) for column-major locality.

def laplace_2d_coarray(nx: int, ny: int, rtol: float, maxiter: int):
    me: int = this_image()  # Local image id (0-based)
    np: int = num_images()  # Total image count

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

    # Compute this image's row range (contiguous band of rows).
    # Each image owns rows [row_start, row_start + local_ny).
    base_rows: int = ny / np  # Base row count per image
    rem_rows: int = ny % np  # Extra rows for first rem images
    local_ny: int = 0  # Rows owned by this image
    row_start: int = 0  # Global row index of first owned row

    if me < rem_rows:
        local_ny = base_rows + 1  # One extra row for early images
        row_start = me * (base_rows + 1)  # Dense prefix offset
    else:
        local_ny = base_rows  # Uniform trailing block
        row_start = rem_rows * (base_rows + 1) + (me - rem_rows) * base_rows  # Tail offset

    # Each image allocates local_ny+2 rows: one ghost row on each side.
    nrows_buf: int = local_ny + 2  # Buffer height with ghost rows

    # Allocate local grids (nrows_buf x nx)
    phi_local: array[float, :, :]  # Local solution (with ghosts)
    pn_local: array[float, :, :]   # Previous iterate (with ghosts)
    y_global: array[float, :]      # Full y-axis coordinates

    allocate(phi_local, nrows_buf, nx)
    allocate(pn_local, nrows_buf, nx)
    allocate(y_global, ny)

    # Build full y coordinate vector (all images need it for BC)
    for j in range(ny):
        y_global[j] = ymin + j * dy  # Uniform spacing

    # Initialize local phi to ones
    for i in range(nx):
        for j in range(nrows_buf):
            phi_local[j, i] = 1.0  # Flat initial guess

    # Coarray buffers for ghost-row exchange.
    # Each image publishes its first and last owned rows.
    ghost_top: array*[float, :]  # Top owned row published for neighbor below
    ghost_bot: array*[float, :]  # Bottom owned row published for neighbor above

    allocate(ghost_top, nx)
    allocate(ghost_bot, nx)

    # Norm reduction buffer: [sum_err, sum_abs] per image
    norm_parts: array*[float, :]
    allocate(norm_parts, 2)

    l1norm: float = 2.0 * rtol  # Ensure at least one iteration
    niter: int = 0
    local_sum_err: float = 0.0  # Local error numerator
    local_sum_abs: float = 0.0  # Local reference denominator
    total_sum_err: float = 0.0  # Global error numerator
    total_sum_abs: float = 0.0  # Global reference denominator
    global_j: int = 0  # Mapped global row index

    # Precompute owned-row bounds for the stencil (skip global boundary rows)
    jj_lo: int = 1  # Default inner start (first owned row in buffer)
    jj_hi: int = local_ny  # Default inner end (last owned row in buffer)

    if row_start == 0:
        jj_lo = 2  # Skip global row 0 (Neumann BC applied later)

    if row_start + local_ny == ny:
        jj_hi = local_ny - 1  # Skip global last row (Neumann BC applied later)

    # Jacobi iteration
    while l1norm > rtol:
        if niter >= maxiter:
            pass  # Bail out at the iteration cap.
        else:
            # Publish boundary rows for ghost exchange
            for i in range(nx):
                ghost_top[i] = phi_local[1, i]  # First owned row (index 1 in buffer)
            for i in range(nx):
                ghost_bot[i] = phi_local[local_ny, i]  # Last owned row

            sync

            # Fill ghost rows from neighbors
            if me > 0:
                for i in range(nx):
                    phi_local[0, i] = ghost_bot[i]{me - 1}  # Bottom row of image above

            if me < np - 1:
                for i in range(nx):
                    phi_local[local_ny + 1, i] = ghost_top[i]{me + 1}  # Top row of image below

            sync

            # Copy phi_local into pn_local (column-major order)
            for i in range(nx):
                for j in range(nrows_buf):
                    pn_local[j, i] = phi_local[j, i]  # Snapshot current iterate.

            # Update interior points with 5-point stencil (column-major order)
            for i in range(1, nx - 1):
                for jj in range(jj_lo, jj_hi + 1):
                    phi_local[jj, i] = (dy2 * (pn_local[jj, i + 1] + pn_local[jj, i - 1]) + dx2 * (pn_local[jj + 1, i] + pn_local[jj - 1, i])) / denom  # Jacobi stencil

            # Apply boundary conditions on owned rows
            for jj in range(1, local_ny + 1):
                phi_local[jj, 0] = 0.0  # phi = 0 at x = xmin

            for jj in range(1, local_ny + 1):
                global_j = row_start + jj - 1  # Map to global row
                phi_local[jj, nx - 1] = y_global[global_j]  # phi = y at x = xmax

            # Neumann BC at y boundaries (first/last global rows copy neighbor)
            if me == 0:
                for i in range(nx):
                    phi_local[1, i] = phi_local[2, i]  # dphi/dy = 0 at y = ymin

            if me == np - 1:
                for i in range(nx):
                    phi_local[local_ny, i] = phi_local[local_ny - 1, i]  # dphi/dy = 0 at y = ymax

            # Compute local contribution to relative L1 norm (column-major order)
            local_sum_err = 0.0
            local_sum_abs = 0.0
            for i in range(nx):
                for jj in range(1, local_ny + 1):
                    local_sum_err += abs(phi_local[jj, i] - pn_local[jj, i])  # Absolute difference
                    local_sum_abs += abs(pn_local[jj, i])  # Reference magnitude

            # Publish local norms for global reduction
            norm_parts[0] = local_sum_err  # Local error sum
            norm_parts[1] = local_sum_abs  # Local reference sum

            sync

            # Image 0 collects and broadcasts the global norm
            if me == 0:
                total_sum_err = 0.0
                total_sum_abs = 0.0
                for img in range(np):
                    total_sum_err += norm_parts[0]{img}  # Gather error sums
                    total_sum_abs += norm_parts[1]{img}  # Gather reference sums
                l1norm = total_sum_err / total_sum_abs  # Global convergence measure
                norm_parts[0] = l1norm  # Reuse buffer to broadcast

            sync

            # All images read the global norm from image 0
            l1norm = norm_parts[0]{0}  # Broadcast from image 0

            sync

            niter += 1

    # Compute local sum(phi) for verification (column-major order)
    local_sum_phi: float = 0.0
    for i in range(nx):
        for jj in range(1, local_ny + 1):
            local_sum_phi += phi_local[jj, i]  # Accumulate owned rows.

    norm_parts[0] = local_sum_phi  # Reuse coarray for sum reduction

    sync

    if me == 0:
        sum_phi: float = 0.0
        for img in range(np):
            sum_phi += norm_parts[0]{img}  # Gather local sums
        print("sum(phi):", sum_phi)
        print("niter:", niter)

def main():
    laplace_2d_coarray(5000, 5000, 1e-6, 5000)  # Match the Python benchmark inputs.

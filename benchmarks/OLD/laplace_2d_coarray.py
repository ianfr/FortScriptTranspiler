# Coarray FortScript port of benchmarks/laplace_2d.py.
# Each image owns a vertical band of columns and exchanges halo columns.
# The domain is [0,2] x [0,1] with nx columns and ny rows total.
# Loop order: outer over local columns (ii), inner over rows (j) for locality.

def laplace_2d_coarray(nx: int, ny: int, rtol: float, maxiter: int):
    me: int = this_image()  # Local image id, 0-based.
    np: int = num_images()  # Total image count.

    # Domain bounds.
    xmin: float = 0.0
    xmax: float = 2.0
    ymin: float = 0.0
    ymax: float = 1.0

    # Grid spacing.
    dx: float = (xmax - xmin) / (nx - 1)
    dy: float = (ymax - ymin) / (ny - 1)

    # Precompute stencil coefficients.
    dx2: float = dx * dx
    dy2: float = dy * dy
    denom: float = 2.0 * (dx2 + dy2)

    # Compute this image's column range.
    base_cols: int = nx / np  # Base column count per image.
    rem_cols: int = nx % np  # Extra columns for first rem images.
    local_nx: int = 0  # Columns owned by this image.
    col_start: int = 0  # Global column index of first owned column.

    if me < rem_cols:
        local_nx = base_cols + 1  # One extra column for early images.
        col_start = me * (base_cols + 1)  # Dense prefix offset.
    else:
        local_nx = base_cols  # Uniform trailing block.
        col_start = rem_cols * (base_cols + 1) + (me - rem_cols) * base_cols  # Tail offset.

    # Each image allocates local_nx+2 columns: one halo on each side.
    ncols_buf: int = local_nx + 2  # Buffer width with halo columns.

    # Allocate local grids as ny x ncols_buf.
    phi_local: array[float, :, :]  # Local solution with halos.
    pn_local: array[float, :, :]  # Previous iterate with halos.

    allocate(phi_local, ny, ncols_buf)
    allocate(pn_local, ny, ncols_buf)

    # Initialize local phi to ones.
    for ii in range(ncols_buf):
        for j in range(ny):
            phi_local[j, ii] = 1.0  # Flat initial guess.

    # Coarray buffers for contiguous halo-column exchange.
    halo_left: array*[float, :]  # First owned column for the left neighbor.
    halo_right: array*[float, :]  # Last owned column for the right neighbor.

    allocate(halo_left, ny)
    allocate(halo_right, ny)

    # Collective reduction buffer: [sum_err, sum_abs].
    reduce_parts: array*[float, :]
    allocate(reduce_parts, 2)

    sum_phi: float* = 0.0  # Collective checksum value.

    l1norm: float = 2.0 * rtol  # Ensure at least one iteration.
    niter: int = 0
    local_sum_err: float = 0.0  # Local error numerator.
    local_sum_abs: float = 0.0  # Local reference denominator.
    total_sum_err: float = 0.0  # Global error numerator.
    total_sum_abs: float = 0.0  # Global reference denominator.
    y: float = 0.0  # Current y coordinate.

    # Precompute owned-column bounds for the stencil.
    ii_lo: int = 1  # First owned column in buffer.
    ii_hi: int = local_nx  # Last owned column in buffer.

    if col_start == 0:
        ii_lo = 2  # Skip global x-min boundary column.

    if col_start + local_nx == nx:
        ii_hi = local_nx - 1  # Skip global x-max boundary column.

    # Jacobi iteration.
    while l1norm > rtol:
        if niter >= maxiter:
            break  # Stop at the iteration cap.
        else:
            # Publish owned edge columns for halo exchange.
            for j in range(ny):
                halo_left[j] = phi_local[j, 1]  # First owned column.
                halo_right[j] = phi_local[j, local_nx]  # Last owned column.

            sync

            # Fill halo columns from neighboring images.
            if me > 0:
                for j in range(ny):
                    phi_local[j, 0] = halo_right[j]{me - 1}  # Left halo.

            if me < np - 1:
                for j in range(ny):
                    phi_local[j, local_nx + 1] = halo_left[j]{me + 1}  # Right halo.

            sync

            # Copy phi_local into pn_local.
            for ii in range(ncols_buf):
                for j in range(ny):
                    pn_local[j, ii] = phi_local[j, ii]  # Snapshot current iterate.

            # Update interior points with 5-point stencil.
            for ii in range(ii_lo, ii_hi + 1):
                for j in range(1, ny - 1):
                    phi_local[j, ii] = (dy2 * (pn_local[j, ii + 1] + pn_local[j, ii - 1]) + dx2 * (pn_local[j + 1, ii] + pn_local[j - 1, ii])) / denom  # Jacobi stencil.

            # Apply Dirichlet boundary conditions on owned x boundaries.
            if col_start == 0:
                for j in range(ny):
                    phi_local[j, 1] = 0.0  # phi = 0 at x = xmin.

            if col_start + local_nx == nx:
                for j in range(ny):
                    y = ymin + j * dy  # Local y coordinate.
                    phi_local[j, local_nx] = y  # phi = y at x = xmax.

            # Apply Neumann boundary conditions on all owned columns.
            for ii in range(1, local_nx + 1):
                phi_local[0, ii] = phi_local[1, ii]  # dphi/dy = 0 at y = ymin.
                phi_local[ny - 1, ii] = phi_local[ny - 2, ii]  # dphi/dy = 0 at y = ymax.

            # Compute local contribution to relative L1 norm.
            local_sum_err = 0.0
            local_sum_abs = 0.0
            for ii in range(1, local_nx + 1):
                for j in range(ny):
                    local_sum_err += abs(phi_local[j, ii] - pn_local[j, ii])  # Absolute difference.
                    local_sum_abs += abs(pn_local[j, ii])  # Reference magnitude.

            # Reduce local norms across all images.
            reduce_parts[0] = local_sum_err  # Local error sum.
            reduce_parts[1] = local_sum_abs  # Local reference sum.
            co_sum(reduce_parts)  # Global error and reference sums.
            total_sum_err = reduce_parts[0]  # Cache the reduced error sum.
            total_sum_abs = reduce_parts[1]  # Cache the reduced reference sum.
            l1norm = total_sum_err / total_sum_abs  # Global convergence measure.

            niter += 1

    # Compute sum(phi) for verification.
    local_sum_phi: float = 0.0
    for ii in range(1, local_nx + 1):
        for j in range(ny):
            local_sum_phi += phi_local[j, ii]  # Accumulate owned columns.

    sum_phi = local_sum_phi  # Publish the local checksum.
    co_sum(sum_phi)  # Sum the checksum across all images.
    sync  # Keep all images aligned before image 0 reports.

    if me == 0:
        print("sum(phi):", sum_phi)
        print("niter:", niter)

def main():
    laplace_2d_coarray(5000, 5000, 1e-6, 5000)  # Match the Python benchmark inputs.

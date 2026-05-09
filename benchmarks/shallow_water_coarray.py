# Coarray FortScript port of benchmarks/python/shallow_water.py.
# Local arrays hold the compute tiles, and 2D coarrays hold halo buffers.

def update_velocity_local(block_nx: int, block_ny: int, x_start: int, y_start: int,
                          nx: int, ny: int, lx: float, ly: float, g: float,
                          f0: float, beta: float, dt: float,
                          u_cur: array[float, :, :], v_cur: array[float, :, :],
                          eta_cur: array[float, :, :],
                          u_next: array[float, :, :], v_next: array[float, :, :]):
    dx: float = lx / (nx - 1)  # Grid spacing in x.
    dy: float = ly / (ny - 1)  # Grid spacing in y.
    global_i: int = 0  # Global x index.
    global_j: int = 0  # Global y index.
    y: float = 0.0  # Physical y coordinate.
    alpha: float = 0.0  # Coriolis factor.
    beta_c: float = 0.0  # Coriolis corrector factor.
    denom: float = 1.0  # Coriolis denominator.

    for jj in range(1, block_ny + 1):
        global_j = y_start + jj - 1  # Global y index.
        y = -ly / 2.0 + global_j * dy  # Physical y coordinate.
        alpha = dt * (f0 + beta * y)  # Local Coriolis coefficient.
        beta_c = alpha * alpha / 4.0  # Corrector coefficient.
        denom = 1.0 + beta_c  # Corrector denominator.
        for ii in range(1, block_nx + 1):
            global_i = x_start + ii - 1  # Global x index.
            if global_i == nx - 1:
                u_next[ii, jj] = 0.0  # Eastern boundary condition.
            else:
                u_next[ii, jj] = u_cur[ii, jj] - g * dt / dx * (eta_cur[ii + 1, jj] - eta_cur[ii, jj])

            if global_j == ny - 1:
                v_next[ii, jj] = 0.0  # Northern boundary condition.
            else:
                v_next[ii, jj] = v_cur[ii, jj] - g * dt / dy * (eta_cur[ii, jj + 1] - eta_cur[ii, jj])

            u_next[ii, jj] = (u_next[ii, jj] - beta_c * u_cur[ii, jj] + alpha * v_cur[ii, jj]) / denom
            v_next[ii, jj] = (v_next[ii, jj] - beta_c * v_cur[ii, jj] - alpha * u_cur[ii, jj]) / denom

def update_eta_local(block_nx: int, block_ny: int, x_start: int, y_start: int,
                     nx: int, ny: int, lx: float, ly: float, h0: float, dt: float,
                     u_next: array[float, :, :], v_next: array[float, :, :],
                     eta_cur: array[float, :, :], eta_next: array[float, :, :]):
    dx: float = lx / (nx - 1)  # Grid spacing in x.
    dy: float = ly / (ny - 1)  # Grid spacing in y.
    global_i: int = 0  # Global x index.
    global_j: int = 0  # Global y index.
    h_left: float = 0.0  # Upwind height from the left cell.
    h_right: float = 0.0  # Upwind height from the right cell.
    h_down: float = 0.0  # Upwind height from the lower cell.
    h_up: float = 0.0  # Upwind height from the upper cell.
    flux_e: float = 0.0  # East face flux.
    flux_w: float = 0.0  # West face flux.
    flux_n: float = 0.0  # North face flux.
    flux_s: float = 0.0  # South face flux.
    u_face: float = 0.0  # x velocity on a face.
    v_face: float = 0.0  # y velocity on a face.

    for jj in range(1, block_ny + 1):
        global_j = y_start + jj - 1  # Global y index.
        for ii in range(1, block_nx + 1):
            global_i = x_start + ii - 1  # Global x index.

            if global_i == nx - 1:
                flux_e = 0.0  # No eastward flux through the wall.
            else:
                h_left = eta_cur[ii, jj] + h0  # Height on the west side of the face.
                h_right = eta_cur[ii + 1, jj] + h0  # Height on the east side of the face.
                if u_next[ii, jj] > 0.0:
                    flux_e = u_next[ii, jj] * h_left  # Upwind from the west.
                else:
                    flux_e = u_next[ii, jj] * h_right  # Upwind from the east.

            if global_i == 0:
                flux_w = 0.0  # No westward boundary face in the Python stencil.
            else:
                h_left = eta_cur[ii - 1, jj] + h0  # Height on the west side of the face.
                h_right = eta_cur[ii, jj] + h0  # Height on the east side of the face.
                u_face = u_next[ii - 1, jj]  # Velocity on the west face.
                if u_face > 0.0:
                    flux_w = u_face * h_left  # Upwind from the west.
                else:
                    flux_w = u_face * h_right  # Upwind from the east.

            if global_j == ny - 1:
                flux_n = 0.0  # No northward flux through the wall.
            else:
                h_down = eta_cur[ii, jj] + h0  # Height on the south side of the face.
                h_up = eta_cur[ii, jj + 1] + h0  # Height on the north side of the face.
                if v_next[ii, jj] > 0.0:
                    flux_n = v_next[ii, jj] * h_down  # Upwind from the south.
                else:
                    flux_n = v_next[ii, jj] * h_up  # Upwind from the north.

            if global_j == 0:
                flux_s = 0.0  # No southward boundary face in the Python stencil.
            else:
                h_down = eta_cur[ii, jj - 1] + h0  # Height on the south side of the face.
                h_up = eta_cur[ii, jj] + h0  # Height on the north side of the face.
                v_face = v_next[ii, jj - 1]  # Velocity on the south face.
                if v_face > 0.0:
                    flux_s = v_face * h_down  # Upwind from the south.
                else:
                    flux_s = v_face * h_up  # Upwind from the north.

            eta_next[ii, jj] = eta_cur[ii, jj] - dt * ((flux_e - flux_w) / dx + (flux_n - flux_s) / dy)

def checksum_local(block_nx: int, block_ny: int, a: array[float, :, :]) -> float:
    total: float = 0.0  # Running checksum.

    for jj in range(1, block_ny + 1):
        for ii in range(1, block_nx + 1):
            total += a[ii, jj]  # Add one owned cell.
    return total

def main():
    nx: int = 16000  # Current benchmark grid for local testing.
    ny: int = 16000  # Current benchmark grid for local testing.
    max_time_step: int = 100  # Match the Python benchmark step count.
    lx: float = 1.0E+6  # Domain length in x.
    ly: float = 1.0E+6  # Domain length in y.
    g: float = 9.81  # Gravity.
    h0: float = 100.0  # Resting fluid depth.
    f0: float = 1.0E-4  # Base Coriolis parameter.
    beta: float = 2.0E-11  # Coriolis gradient.
    dx: float = lx / (nx - 1)  # Grid spacing in x.
    dy: float = ly / (ny - 1)  # Grid spacing in y.
    dt: float = 0.1 * dx / sqrt(g * h0)  # CFL-limited timestep.
    me: int = this_image()  # Local image id.
    np: int = num_images()  # Total image count.
    nrows_p: int = 4  # Process rows for the 2D coarray grid.
    ncols_p: int = 0  # Process columns for the 2D coarray grid.
    row_img: int = 0  # Image row in the 2D process grid.
    col_img: int = 0  # Image column in the 2D process grid.
    block_nx: int = 0  # Owned x cells on this image.
    block_ny: int = 0  # Owned y cells on this image.
    x_start: int = 0  # Global x index of the first owned cell.
    y_start: int = 0  # Global y index of the first owned cell.
    global_i: int = 0  # Global x index.
    global_j: int = 0  # Global y index.
    x: float = 0.0  # Physical x coordinate.
    y: float = 0.0  # Physical y coordinate.
    x0: float = lx / 2.7  # Gaussian center in x.
    y0: float = ly / 4.0  # Gaussian center in y.
    sigma: float = 0.05E+6  # Gaussian width.
    r2: float = 0.0  # Scaled squared radius.
    final_in_b: bool = False  # Tracks the active ping-pong buffer.
    local_eta: float = 0.0  # Local checksum contribution.
    local_u: float = 0.0  # Local checksum contribution.
    local_v: float = 0.0  # Local checksum contribution.
    sum_eta: float* = 0.0  # Global eta checksum.
    sum_u: float* = 0.0  # Global u checksum.
    sum_v: float* = 0.0  # Global v checksum.
    u_a: array[float, :, :]  # First local x velocity tile.
    v_a: array[float, :, :]  # First local y velocity tile.
    eta_a: array[float, :, :]  # First local surface elevation tile.
    u_b: array[float, :, :]  # Second local x velocity tile.
    v_b: array[float, :, :]  # Second local y velocity tile.
    eta_b: array[float, :, :]  # Second local surface elevation tile.
    eta_w: array*[float, :][:]  # West eta edge exchange buffer.
    eta_e: array*[float, :][:]  # East eta edge exchange buffer.
    eta_s: array*[float, :][:]  # South eta edge exchange buffer.
    eta_n: array*[float, :][:]  # North eta edge exchange buffer.
    u_w: array*[float, :][:]  # West u edge exchange buffer.
    u_e: array*[float, :][:]  # East u edge exchange buffer.
    u_s: array*[float, :][:]  # South u edge exchange buffer.
    u_north: array*[float, :][:]  # North u edge exchange buffer.
    v_w: array*[float, :][:]  # West v edge exchange buffer.
    v_e: array*[float, :][:]  # East v edge exchange buffer.
    v_s: array*[float, :][:]  # South v edge exchange buffer.
    v_north: array*[float, :][:]  # North v edge exchange buffer.

    if np % nrows_p != 0:
        if me == 0:
            print("shallow_water_coarray expects num_images() divisible by 4")
        return

    ncols_p = np / nrows_p  # Complete the 2D process grid.
    if nx % ncols_p != 0:
        if me == 0:
            print("shallow_water_coarray expects nx divisible by process columns")
        return
    if ny % nrows_p != 0:
        if me == 0:
            print("shallow_water_coarray expects ny divisible by process rows")
        return

    row_img = me % nrows_p  # First coindex varies fastest in Fortran.
    col_img = me / nrows_p  # Second coindex is the slower image coordinate.
    block_nx = nx / ncols_p  # Uniform x block.
    block_ny = ny / nrows_p  # Uniform y block.
    x_start = col_img * block_nx  # Global x offset.
    y_start = row_img * block_ny  # Global y offset.

    allocate(u_a, block_nx + 2, block_ny + 2)
    allocate(v_a, block_nx + 2, block_ny + 2)
    allocate(eta_a, block_nx + 2, block_ny + 2)
    allocate(u_b, block_nx + 2, block_ny + 2)
    allocate(v_b, block_nx + 2, block_ny + 2)
    allocate(eta_b, block_nx + 2, block_ny + 2)
    allocate(eta_w, block_ny, nrows_p)
    allocate(eta_e, block_ny, nrows_p)
    allocate(eta_s, block_nx, nrows_p)
    allocate(eta_n, block_nx, nrows_p)
    allocate(u_w, block_ny, nrows_p)
    allocate(u_e, block_ny, nrows_p)
    allocate(u_s, block_nx, nrows_p)
    allocate(u_north, block_nx, nrows_p)
    allocate(v_w, block_ny, nrows_p)
    allocate(v_e, block_ny, nrows_p)
    allocate(v_s, block_nx, nrows_p)
    allocate(v_north, block_nx, nrows_p)

    for jj in range(block_ny + 2):
        for ii in range(block_nx + 2):
            u_a[ii, jj] = 0.0  # Clear first x velocity buffer.
            v_a[ii, jj] = 0.0  # Clear first y velocity buffer.
            eta_a[ii, jj] = 0.0  # Clear first elevation buffer.
            u_b[ii, jj] = 0.0  # Clear second x velocity buffer.
            v_b[ii, jj] = 0.0  # Clear second y velocity buffer.
            eta_b[ii, jj] = 0.0  # Clear second elevation buffer.

    for jj in range(1, block_ny + 1):
        global_j = y_start + jj - 1  # Global y index.
        y = -ly / 2.0 + global_j * dy  # Physical y coordinate.
        for ii in range(1, block_nx + 1):
            global_i = x_start + ii - 1  # Global x index.
            x = -lx / 2.0 + global_i * dx  # Physical x coordinate.
            r2 = ((x - x0) * (x - x0) + (y - y0) * (y - y0)) / (2.0 * sigma * sigma)
            eta_a[ii, jj] = exp(-r2)  # Initial surface elevation.

    sync

    for step in range(1, max_time_step):
        if final_in_b:
            for jj in range(1, block_ny + 1):
                eta_w[jj - 1] = eta_b[1, jj]  # Publish west eta edge.
                eta_e[jj - 1] = eta_b[block_nx, jj]  # Publish east eta edge.
            for ii in range(1, block_nx + 1):
                eta_s[ii - 1] = eta_b[ii, 1]  # Publish south eta edge.
                eta_n[ii - 1] = eta_b[ii, block_ny]  # Publish north eta edge.
            sync
            if col_img > 0:
                eta_b[0, 1:block_ny + 1] = eta_e[0:block_ny]{row_img, col_img - 1}  # Load west eta halo.
            if col_img < ncols_p - 1:
                eta_b[block_nx + 1, 1:block_ny + 1] = eta_w[0:block_ny]{row_img, col_img + 1}  # Load east eta halo.
            if row_img > 0:
                eta_b[1:block_nx + 1, 0] = eta_n[0:block_nx]{row_img - 1, col_img}  # Load south eta halo.
            if row_img < nrows_p - 1:
                eta_b[1:block_nx + 1, block_ny + 1] = eta_s[0:block_nx]{row_img + 1, col_img}  # Load north eta halo.
            sync

            update_velocity_local(block_nx, block_ny, x_start, y_start, nx, ny,
                                  lx, ly, g, f0, beta, dt, u_b, v_b, eta_b, u_a, v_a)

            for jj in range(1, block_ny + 1):
                u_w[jj - 1] = u_a[1, jj]  # Publish west u edge.
                u_e[jj - 1] = u_a[block_nx, jj]  # Publish east u edge.
                v_w[jj - 1] = v_a[1, jj]  # Publish west v edge.
                v_e[jj - 1] = v_a[block_nx, jj]  # Publish east v edge.
            for ii in range(1, block_nx + 1):
                u_s[ii - 1] = u_a[ii, 1]  # Publish south u edge.
                u_north[ii - 1] = u_a[ii, block_ny]  # Publish north u edge.
                v_s[ii - 1] = v_a[ii, 1]  # Publish south v edge.
                v_north[ii - 1] = v_a[ii, block_ny]  # Publish north v edge.
            sync
            if col_img > 0:
                u_a[0, 1:block_ny + 1] = u_e[0:block_ny]{row_img, col_img - 1}  # Load west u halo.
                v_a[0, 1:block_ny + 1] = v_e[0:block_ny]{row_img, col_img - 1}  # Load west v halo.
            if col_img < ncols_p - 1:
                u_a[block_nx + 1, 1:block_ny + 1] = u_w[0:block_ny]{row_img, col_img + 1}  # Load east u halo.
                v_a[block_nx + 1, 1:block_ny + 1] = v_w[0:block_ny]{row_img, col_img + 1}  # Load east v halo.
            if row_img > 0:
                u_a[1:block_nx + 1, 0] = u_north[0:block_nx]{row_img - 1, col_img}  # Load south u halo.
                v_a[1:block_nx + 1, 0] = v_north[0:block_nx]{row_img - 1, col_img}  # Load south v halo.
            if row_img < nrows_p - 1:
                u_a[1:block_nx + 1, block_ny + 1] = u_s[0:block_nx]{row_img + 1, col_img}  # Load north u halo.
                v_a[1:block_nx + 1, block_ny + 1] = v_s[0:block_nx]{row_img + 1, col_img}  # Load north v halo.
            sync

            update_eta_local(block_nx, block_ny, x_start, y_start, nx, ny,
                             lx, ly, h0, dt, u_a, v_a, eta_b, eta_a)
            final_in_b = False  # The first buffer now holds the active fields.
        else:
            for jj in range(1, block_ny + 1):
                eta_w[jj - 1] = eta_a[1, jj]  # Publish west eta edge.
                eta_e[jj - 1] = eta_a[block_nx, jj]  # Publish east eta edge.
            for ii in range(1, block_nx + 1):
                eta_s[ii - 1] = eta_a[ii, 1]  # Publish south eta edge.
                eta_n[ii - 1] = eta_a[ii, block_ny]  # Publish north eta edge.
            sync
            if col_img > 0:
                eta_a[0, 1:block_ny + 1] = eta_e[0:block_ny]{row_img, col_img - 1}  # Load west eta halo.
            if col_img < ncols_p - 1:
                eta_a[block_nx + 1, 1:block_ny + 1] = eta_w[0:block_ny]{row_img, col_img + 1}  # Load east eta halo.
            if row_img > 0:
                eta_a[1:block_nx + 1, 0] = eta_n[0:block_nx]{row_img - 1, col_img}  # Load south eta halo.
            if row_img < nrows_p - 1:
                eta_a[1:block_nx + 1, block_ny + 1] = eta_s[0:block_nx]{row_img + 1, col_img}  # Load north eta halo.
            sync

            update_velocity_local(block_nx, block_ny, x_start, y_start, nx, ny,
                                  lx, ly, g, f0, beta, dt, u_a, v_a, eta_a, u_b, v_b)

            for jj in range(1, block_ny + 1):
                u_w[jj - 1] = u_b[1, jj]  # Publish west u edge.
                u_e[jj - 1] = u_b[block_nx, jj]  # Publish east u edge.
                v_w[jj - 1] = v_b[1, jj]  # Publish west v edge.
                v_e[jj - 1] = v_b[block_nx, jj]  # Publish east v edge.
            for ii in range(1, block_nx + 1):
                u_s[ii - 1] = u_b[ii, 1]  # Publish south u edge.
                u_north[ii - 1] = u_b[ii, block_ny]  # Publish north u edge.
                v_s[ii - 1] = v_b[ii, 1]  # Publish south v edge.
                v_north[ii - 1] = v_b[ii, block_ny]  # Publish north v edge.
            sync
            if col_img > 0:
                u_b[0, 1:block_ny + 1] = u_e[0:block_ny]{row_img, col_img - 1}  # Load west u halo.
                v_b[0, 1:block_ny + 1] = v_e[0:block_ny]{row_img, col_img - 1}  # Load west v halo.
            if col_img < ncols_p - 1:
                u_b[block_nx + 1, 1:block_ny + 1] = u_w[0:block_ny]{row_img, col_img + 1}  # Load east u halo.
                v_b[block_nx + 1, 1:block_ny + 1] = v_w[0:block_ny]{row_img, col_img + 1}  # Load east v halo.
            if row_img > 0:
                u_b[1:block_nx + 1, 0] = u_north[0:block_nx]{row_img - 1, col_img}  # Load south u halo.
                v_b[1:block_nx + 1, 0] = v_north[0:block_nx]{row_img - 1, col_img}  # Load south v halo.
            if row_img < nrows_p - 1:
                u_b[1:block_nx + 1, block_ny + 1] = u_s[0:block_nx]{row_img + 1, col_img}  # Load north u halo.
                v_b[1:block_nx + 1, block_ny + 1] = v_s[0:block_nx]{row_img + 1, col_img}  # Load north v halo.
            sync

            update_eta_local(block_nx, block_ny, x_start, y_start, nx, ny,
                             lx, ly, h0, dt, u_b, v_b, eta_a, eta_b)
            final_in_b = True  # The second buffer now holds the active fields.

        sync

    if final_in_b:
        local_eta = checksum_local(block_nx, block_ny, eta_b)
        local_u = checksum_local(block_nx, block_ny, u_b)
        local_v = checksum_local(block_nx, block_ny, v_b)
    else:
        local_eta = checksum_local(block_nx, block_ny, eta_a)
        local_u = checksum_local(block_nx, block_ny, u_a)
        local_v = checksum_local(block_nx, block_ny, v_a)

    sum_eta = local_eta  # Publish local eta checksum.
    sum_u = local_u  # Publish local u checksum.
    sum_v = local_v  # Publish local v checksum.
    co_sum(sum_eta)
    co_sum(sum_u)
    co_sum(sum_v)
    sync

    if me == 0:
        print("Shallow water coarray nx=", nx, "ny=", ny, "steps=", max_time_step - 1)
        print("process grid:", nrows_p, "x", ncols_p)
        print("sum_eta:", sum_eta)
        print("sum_u:", sum_u)
        print("sum_v:", sum_v)

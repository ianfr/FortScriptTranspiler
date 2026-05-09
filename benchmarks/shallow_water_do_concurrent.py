# do concurrent FortScript port of benchmarks/python/shallow_water.py.
# The update kernels are marked with @par and report checksums.

def initialize_eta(nx: int, ny: int, lx: float, ly: float,
                   eta: array[float, :, :]):
    x: float = 0.0  # Physical x coordinate.
    y: float = 0.0  # Physical y coordinate.
    dx: float = lx / (nx - 1)  # Grid spacing in x.
    dy: float = ly / (ny - 1)  # Grid spacing in y.
    x0: float = lx / 2.7  # Gaussian center in x.
    y0: float = ly / 4.0  # Gaussian center in y.
    sigma: float = 0.05E+6  # Gaussian width.
    r2: float = 0.0  # Scaled squared radius.

    @par
    @local(x)
    @local(y)
    @local(r2)
    for j in range(ny):
        y = -ly / 2.0 + j * dy  # Match the Python grid coordinates.
        for i in range(nx):
            x = -lx / 2.0 + i * dx  # Match the Python grid coordinates.
            r2 = ((x - x0) * (x - x0) + (y - y0) * (y - y0)) / (2.0 * sigma * sigma)
            eta[i, j] = exp(-r2)  # Initial surface elevation.

def initialize_zero(nx: int, ny: int, a: array[float, :, :]):
    @par
    for j in range(ny):
        for i in range(nx):
            a[i, j] = 0.0  # Clear the field.

def update_velocity(nx: int, ny: int, lx: float, ly: float, g: float,
                    f0: float, beta: float, dt: float,
                    u_n: array[float, :, :], v_n: array[float, :, :],
                    eta_n: array[float, :, :],
                    u_np1: array[float, :, :], v_np1: array[float, :, :]):
    dx: float = lx / (nx - 1)  # Grid spacing in x.
    dy: float = ly / (ny - 1)  # Grid spacing in y.
    y: float = 0.0  # Physical y coordinate.
    alpha: float = 0.0  # Coriolis factor.
    beta_c: float = 0.0  # Coriolis corrector factor.
    denom: float = 1.0  # Coriolis denominator.

    @par
    @local(y)
    @local(alpha)
    @local(beta_c)
    @local(denom)
    for j in range(ny):
        y = -ly / 2.0 + j * dy  # Coriolis varies only with y.
        alpha = dt * (f0 + beta * y)  # Local Coriolis coefficient.
        beta_c = alpha * alpha / 4.0  # Corrector coefficient.
        denom = 1.0 + beta_c  # Corrector denominator.
        for i in range(nx):
            if i == nx - 1:
                u_np1[i, j] = 0.0  # Eastern boundary condition.
            else:
                u_np1[i, j] = u_n[i, j] - g * dt / dx * (eta_n[i + 1, j] - eta_n[i, j])

            if j == ny - 1:
                v_np1[i, j] = 0.0  # Northern boundary condition.
            else:
                v_np1[i, j] = v_n[i, j] - g * dt / dy * (eta_n[i, j + 1] - eta_n[i, j])

            u_np1[i, j] = (u_np1[i, j] - beta_c * u_n[i, j] + alpha * v_n[i, j]) / denom
            v_np1[i, j] = (v_np1[i, j] - beta_c * v_n[i, j] - alpha * u_n[i, j]) / denom

def update_eta(nx: int, ny: int, lx: float, ly: float, h0: float, dt: float,
               u_np1: array[float, :, :], v_np1: array[float, :, :],
               eta_n: array[float, :, :], eta_np1: array[float, :, :]):
    dx: float = lx / (nx - 1)  # Grid spacing in x.
    dy: float = ly / (ny - 1)  # Grid spacing in y.
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

    @par
    @local(h_left)
    @local(h_right)
    @local(h_down)
    @local(h_up)
    @local(flux_e)
    @local(flux_w)
    @local(flux_n)
    @local(flux_s)
    @local(u_face)
    @local(v_face)
    for j in range(ny):
        for i in range(nx):
            if i == nx - 1:
                flux_e = 0.0  # No eastward flux through the wall.
            else:
                h_left = eta_n[i, j] + h0  # Height on the west side of the face.
                h_right = eta_n[i + 1, j] + h0  # Height on the east side of the face.
                if u_np1[i, j] > 0.0:
                    flux_e = u_np1[i, j] * h_left  # Upwind from the west.
                else:
                    flux_e = u_np1[i, j] * h_right  # Upwind from the east.

            if i == 0:
                flux_w = 0.0  # No westward boundary face in the Python stencil.
            else:
                h_left = eta_n[i - 1, j] + h0  # Height on the west side of the face.
                h_right = eta_n[i, j] + h0  # Height on the east side of the face.
                u_face = u_np1[i - 1, j]  # Velocity on the west face.
                if u_face > 0.0:
                    flux_w = u_face * h_left  # Upwind from the west.
                else:
                    flux_w = u_face * h_right  # Upwind from the east.

            if j == ny - 1:
                flux_n = 0.0  # No northward flux through the wall.
            else:
                h_down = eta_n[i, j] + h0  # Height on the south side of the face.
                h_up = eta_n[i, j + 1] + h0  # Height on the north side of the face.
                if v_np1[i, j] > 0.0:
                    flux_n = v_np1[i, j] * h_down  # Upwind from the south.
                else:
                    flux_n = v_np1[i, j] * h_up  # Upwind from the north.

            if j == 0:
                flux_s = 0.0  # No southward boundary face in the Python stencil.
            else:
                h_down = eta_n[i, j - 1] + h0  # Height on the south side of the face.
                h_up = eta_n[i, j] + h0  # Height on the north side of the face.
                v_face = v_np1[i, j - 1]  # Velocity on the south face.
                if v_face > 0.0:
                    flux_s = v_face * h_down  # Upwind from the south.
                else:
                    flux_s = v_face * h_up  # Upwind from the north.

            eta_np1[i, j] = eta_n[i, j] - dt * ((flux_e - flux_w) / dx + (flux_n - flux_s) / dy)

def checksum(nx: int, ny: int, a: array[float, :, :]) -> float:
    total: float = 0.0  # Running sum.

    @par
    @reduce(add: total)
    for j in range(ny):
        for i in range(nx):
            total += a[i, j]  # Add one grid value.
    return total

def main():
    nx: int = 16000  # Match the Python benchmark grid.
    ny: int = 16000  # Match the Python benchmark grid.
    max_time_step: int = 100  # Match the Python benchmark step count.
    lx: float = 1.0E+6  # Domain length in x.
    ly: float = 1.0E+6  # Domain length in y.
    g: float = 9.81  # Gravity.
    h0: float = 100.0  # Resting fluid depth.
    f0: float = 1.0E-4  # Base Coriolis parameter.
    beta: float = 2.0E-11  # Coriolis gradient.
    dx: float = lx / (nx - 1)  # Grid spacing in x.
    dt: float = 0.1 * dx / sqrt(g * h0)  # CFL-limited timestep.
    u_n: array[float, :, :]  # Current x velocity.
    v_n: array[float, :, :]  # Current y velocity.
    eta_n: array[float, :, :]  # Current surface elevation.
    u_alt: array[float, :, :]  # Alternate x velocity buffer.
    v_alt: array[float, :, :]  # Alternate y velocity buffer.
    eta_alt: array[float, :, :]  # Alternate surface elevation buffer.
    final_in_alt: bool = False  # Tracks the active ping-pong buffer.

    allocate(u_n, nx, ny)
    allocate(v_n, nx, ny)
    allocate(eta_n, nx, ny)
    allocate(u_alt, nx, ny)
    allocate(v_alt, nx, ny)
    allocate(eta_alt, nx, ny)

    initialize_zero(nx, ny, u_n)
    initialize_zero(nx, ny, v_n)
    initialize_zero(nx, ny, u_alt)
    initialize_zero(nx, ny, v_alt)
    initialize_eta(nx, ny, lx, ly, eta_n)

    for step in range(1, max_time_step):
        if step % 2 == 1:
            update_velocity(nx, ny, lx, ly, g, f0, beta, dt, u_n, v_n, eta_n, u_alt, v_alt)
            update_eta(nx, ny, lx, ly, h0, dt, u_alt, v_alt, eta_n, eta_alt)
            final_in_alt = True  # Odd steps write the alternate buffer.
        else:
            update_velocity(nx, ny, lx, ly, g, f0, beta, dt, u_alt, v_alt, eta_alt, u_n, v_n)
            update_eta(nx, ny, lx, ly, h0, dt, u_n, v_n, eta_alt, eta_n)
            final_in_alt = False  # Even steps write the primary buffer.

    print("Shallow water do concurrent nx=", nx, "ny=", ny, "steps=", max_time_step - 1)
    if final_in_alt:
        print("sum_eta:", checksum(nx, ny, eta_alt))
        print("sum_u:", checksum(nx, ny, u_alt))
        print("sum_v:", checksum(nx, ny, v_alt))
    else:
        print("sum_eta:", checksum(nx, ny, eta_n))
        print("sum_u:", checksum(nx, ny, u_n))
        print("sum_v:", checksum(nx, ny, v_n))

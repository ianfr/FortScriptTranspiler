# Coarray FortScript benchmark for 3D Ising Glauber dynamics.
# The lattice is split into z-slabs and neighboring images exchange ghost planes.

def owned_count(total: int, np: int, img: int) -> int:
    base: int = total / np  # Even slab size before the remainder is distributed.
    rem: int = total % np  # First rem images get one extra plane.
    if img < rem:
        return base + 1  # Prefix slabs are one plane larger.
    return base  # Tail slabs use the base size.

def owned_start(total: int, np: int, img: int) -> int:
    base: int = total / np  # Even slab size before the remainder is distributed.
    rem: int = total % np  # First rem images get one extra plane.
    if img < rem:
        return img * (base + 1)  # Dense prefix offset.
    return rem * (base + 1) + (img - rem) * base  # Tail offset.

def measurement_count(n_meas: int, meas_interval: int) -> int:
    return (n_meas + meas_interval - 1) / meas_interval  # Count retained measurements.

def park_miller_step(state: int) -> int:
    i4_huge: int = 2147483647  # Same modulus used in the MD benchmarks.
    q: int = 0  # Quotient for the Park-Miller recurrence.
    next_state: int = 0  # Advanced RNG state.

    q = state / 127773  # Split the state to avoid overflow in the recurrence.
    next_state = 16807 * (state - q * 127773) - q * 2836  # Advance the RNG state.
    next_state = next_state % i4_huge  # Keep the state inside the valid range.
    if next_state <= 0:
        next_state += i4_huge  # Repair the non-positive corner case.
    return next_state

def site_uniform(base_seed: int, sweep_id: int, phase: int,
                 ix: int, iy: int, global_z: int) -> float:
    i4_huge: int = 2147483647  # Same modulus used in the MD benchmarks.
    state: int = 0  # Mixed integer seed for this lattice site and sweep.

    state = base_seed + 104729 * (ix + 1)  # Mix the x coordinate.
    state += 13007 * (iy + 1)  # Mix the y coordinate.
    state += 7919 * (global_z + 1)  # Mix the z coordinate.
    state += 65537 * (sweep_id + 1)  # Mix the sweep counter.
    state += 17 * (phase + 1)  # Mix the checkerboard phase.
    state = state % i4_huge  # Keep the mixed state in range.
    if state <= 0:
        state += i4_huge - 1  # Repair the zero corner case before stepping.
    state = park_miller_step(state)  # Scramble once.
    state = park_miller_step(state)  # Scramble twice for a less regular pattern.
    return state * 4.656612875E-10  # Map the integer state into [0, 1).

def init_local_spins(L: int, z_start: int, local_nz: int, hot: bool,
                     base_seed: int, spins_local: array[int, :, :, :]):
    global_z: int = 0  # Global z index corresponding to the owned local plane.
    z_local: int = 0  # Local z index inside the owned slab.
    u: float = 0.0  # Uniform random number in [0, 1).

    for z_local in range(local_nz):
        global_z = z_start + z_local  # Map the local plane to the global z axis.
        for iy in range(L):
            for ix in range(L):
                if hot:
                    u = site_uniform(base_seed, 1024, 3, ix, iy, global_z)  # Dedicated initialization stream.
                    if u < 0.5:
                        spins_local[ix, iy, z_local + 1] = -1  # Random down spin.
                    else:
                        spins_local[ix, iy, z_local + 1] = 1  # Random up spin.
                else:
                    spins_local[ix, iy, z_local + 1] = 1  # Cold start below the critical point.

    for iy in range(L):
        for ix in range(L):
            spins_local[ix, iy, 0] = 0  # Clear the lower ghost plane.
            spins_local[ix, iy, local_nz + 1] = 0  # Clear the upper ghost plane.

def glauber_half_sweep_local(spins_local: array[int, :, :, :], L: int, local_nz: int,
                             z_start: int, beta: float, J: float,
                             base_seed: int, sweep_id: int, phase: int):
    global_z: int = 0  # Global z index for the current owned local plane.
    ip: int = 0  # Wrapped +x neighbour
    im: int = 0  # Wrapped -x neighbour
    jp: int = 0  # Wrapped +y neighbour
    jm: int = 0  # Wrapped -y neighbour
    spin: int = 0  # Current site spin.
    h: int = 0  # Local field from the six neighbours.
    arg: float = 0.0  # Glauber logistic argument.
    accept: float = 0.0  # Heat-bath acceptance probability.
    z: float = 0.0  # Uniform random number for the update test.

    for z_local in range(local_nz):
        global_z = z_start + z_local  # Map the local plane to the global z axis.
        for iy in range(L):
            jp = iy + 1  # Candidate +y neighbour.
            if jp == L:
                jp = 0  # Wrap across the periodic boundary.
            jm = iy - 1  # Candidate -y neighbour.
            if jm < 0:
                jm = L - 1  # Wrap across the periodic boundary.

            for ix in range(L):
                if (ix + iy + global_z) % 2 == phase:
                    ip = ix + 1  # Candidate +x neighbour.
                    if ip == L:
                        ip = 0  # Wrap across the periodic boundary.
                    im = ix - 1  # Candidate -x neighbour.
                    if im < 0:
                        im = L - 1  # Wrap across the periodic boundary.

                    spin = spins_local[ix, iy, z_local + 1]  # Cache the current spin value.
                    h = spins_local[ip, iy, z_local + 1] + spins_local[im, iy, z_local + 1]  # x neighbours
                    h += spins_local[ix, jp, z_local + 1] + spins_local[ix, jm, z_local + 1]  # y neighbours
                    h += spins_local[ix, iy, z_local + 2] + spins_local[ix, iy, z_local]  # z neighbours via ghosts

                    arg = 2.0 * J * beta * spin * h  # Local field form of DeltaE / T.
                    accept = 1.0 / (1.0 + exp(arg))  # Glauber heat-bath probability.
                    z = site_uniform(base_seed, sweep_id, phase, ix, iy, global_z)  # Deterministic per-site RNG.
                    if accept > z:
                        spins_local[ix, iy, z_local + 1] = -spin  # Flip the spin when the move is accepted.

def local_magnetization_sum(spins_local: array[int, :, :, :], L: int, local_nz: int) -> int:
    m_sum: int = 0  # Local signed magnetization over the owned planes.

    for z_local in range(local_nz):
        for iy in range(L):
            for ix in range(L):
                m_sum += spins_local[ix, iy, z_local + 1]  # Accumulate the owned spins.
    return m_sum

def local_bond_sum(spins_local: array[int, :, :, :], L: int, local_nz: int) -> int:
    bond_sum: int = 0  # Local sum of positive-direction bonds.
    ip: int = 0  # Wrapped +x neighbour
    jp: int = 0  # Wrapped +y neighbour

    for z_local in range(local_nz):
        for iy in range(L):
            jp = iy + 1  # Candidate +y neighbour.
            if jp == L:
                jp = 0  # Wrap across the periodic boundary.

            for ix in range(L):
                ip = ix + 1  # Candidate +x neighbour.
                if ip == L:
                    ip = 0  # Wrap across the periodic boundary.

                bond_sum += spins_local[ix, iy, z_local + 1] * spins_local[ip, iy, z_local + 1]  # +x bond
                bond_sum += spins_local[ix, iy, z_local + 1] * spins_local[ix, jp, z_local + 1]  # +y bond
                bond_sum += spins_local[ix, iy, z_local + 1] * spins_local[ix, iy, z_local + 2]  # +z bond via ghost
    return bond_sum

def binder_cumulant(mean_m2: float, mean_m4: float) -> float:
    if mean_m2 <= 0.0:
        return 0.0  # Avoid a zero divide in the disordered corner case.
    return 1.0 - mean_m4 / (3.0 * mean_m2 * mean_m2)

def run_ising_coarray(L: int, T: float, J: float, n_therm: int,
                      n_meas: int, meas_interval: int, base_seed: int):
    me: int = this_image()  # Local image id.
    np: int = num_images()  # Total image count.
    n_sites: int = L * L * L  # Global number of spins in the lattice.
    local_nz: int = owned_count(L, np, me)  # Owned z planes on this image.
    z_start: int = owned_start(L, np, me)  # Global z index of the first owned plane.
    down_img: int = me - 1  # Lower-z neighbor image.
    up_img: int = me + 1  # Upper-z neighbor image.
    spins_local: array[int, :, :, :]  # Owned slab with one ghost plane on each side.
    plane_lo: array*[int, :, :]  # Published first owned plane.
    plane_hi: array*[int, :, :]  # Published last owned plane.
    reduce_buffer: array*[float, :]  # Coarray reduction buffer for global observables.
    beta: float = 1.0 / T  # Inverse temperature in units with k_B = 1.
    hot: bool = T > J * 4.5115232  # Cold start below T_c, hot start above.
    sample_count: int = measurement_count(n_meas, meas_interval)  # Exact retained sample count.
    local_m_sum: int = 0  # Local signed magnetization sum.
    local_bonds: int = 0  # Local positive-direction bond sum.
    m_abs: float = 0.0  # Global absolute magnetization per site.
    e: float = 0.0  # Global energy per site.
    m2: float = 0.0  # Second magnetization moment.
    meas_count: int = 0  # Number of retained measurements.
    sum_abs_m: float = 0.0  # Running sum for |m| on image 0.
    sum_m2: float = 0.0  # Running sum for m^2 on image 0.
    sum_m4: float = 0.0  # Running sum for m^4 on image 0.
    sum_e: float = 0.0  # Running sum for e on image 0.
    sum_e2: float = 0.0  # Running sum for e^2 on image 0.
    mean_abs_m: float = 0.0  # Sample mean of |m| on image 0.
    mean_m2: float = 0.0  # Sample mean of m^2 on image 0.
    mean_m4: float = 0.0  # Sample mean of m^4 on image 0.
    mean_e: float = 0.0  # Sample mean of e on image 0.
    mean_e2: float = 0.0  # Sample mean of e^2 on image 0.

    if np > L:
        if me == 0:
            print("ising_glauber_coarray expects num_images() <= L")  # Keep the slab decomposition valid.
        return

    if down_img < 0:
        down_img = np - 1  # Wrap the lower neighbor across the periodic boundary.
    if up_img == np:
        up_img = 0  # Wrap the upper neighbor across the periodic boundary.

    allocate(spins_local, L, L, local_nz + 2)
    allocate(plane_lo, L, L)
    allocate(plane_hi, L, L)
    allocate(reduce_buffer, 2)

    init_local_spins(L, z_start, local_nz, hot, base_seed, spins_local)

    for therm_step in range(n_therm):
        if np == 1:
            spins_local[0:L, 0:L, 0] = spins_local[0:L, 0:L, local_nz]  # Periodic lower ghost from the local last plane.
            spins_local[0:L, 0:L, local_nz + 1] = spins_local[0:L, 0:L, 1]  # Periodic upper ghost from the local first plane.
        else:
            plane_lo[0:L, 0:L] = spins_local[0:L, 0:L, 1]  # Publish the first owned plane.
            plane_hi[0:L, 0:L] = spins_local[0:L, 0:L, local_nz]  # Publish the last owned plane.
            sync
            spins_local[0:L, 0:L, 0] = plane_hi[0:L, 0:L]{down_img}  # Receive the lower ghost plane.
            spins_local[0:L, 0:L, local_nz + 1] = plane_lo[0:L, 0:L]{up_img}  # Receive the upper ghost plane.
            sync
        glauber_half_sweep_local(spins_local, L, local_nz, z_start, beta, J, base_seed, therm_step, 0)

        if np == 1:
            spins_local[0:L, 0:L, 0] = spins_local[0:L, 0:L, local_nz]  # Periodic lower ghost from the local last plane.
            spins_local[0:L, 0:L, local_nz + 1] = spins_local[0:L, 0:L, 1]  # Periodic upper ghost from the local first plane.
        else:
            plane_lo[0:L, 0:L] = spins_local[0:L, 0:L, 1]  # Publish the updated first owned plane.
            plane_hi[0:L, 0:L] = spins_local[0:L, 0:L, local_nz]  # Publish the updated last owned plane.
            sync
            spins_local[0:L, 0:L, 0] = plane_hi[0:L, 0:L]{down_img}  # Receive the lower ghost plane.
            spins_local[0:L, 0:L, local_nz + 1] = plane_lo[0:L, 0:L]{up_img}  # Receive the upper ghost plane.
            sync
        glauber_half_sweep_local(spins_local, L, local_nz, z_start, beta, J, base_seed, therm_step, 1)

    for meas_step in range(n_meas):
        if np == 1:
            spins_local[0:L, 0:L, 0] = spins_local[0:L, 0:L, local_nz]  # Periodic lower ghost from the local last plane.
            spins_local[0:L, 0:L, local_nz + 1] = spins_local[0:L, 0:L, 1]  # Periodic upper ghost from the local first plane.
        else:
            plane_lo[0:L, 0:L] = spins_local[0:L, 0:L, 1]  # Publish the first owned plane.
            plane_hi[0:L, 0:L] = spins_local[0:L, 0:L, local_nz]  # Publish the last owned plane.
            sync
            spins_local[0:L, 0:L, 0] = plane_hi[0:L, 0:L]{down_img}  # Receive the lower ghost plane.
            spins_local[0:L, 0:L, local_nz + 1] = plane_lo[0:L, 0:L]{up_img}  # Receive the upper ghost plane.
            sync
        glauber_half_sweep_local(spins_local, L, local_nz, z_start, beta, J, base_seed, n_therm + meas_step, 0)

        if np == 1:
            spins_local[0:L, 0:L, 0] = spins_local[0:L, 0:L, local_nz]  # Periodic lower ghost from the local last plane.
            spins_local[0:L, 0:L, local_nz + 1] = spins_local[0:L, 0:L, 1]  # Periodic upper ghost from the local first plane.
        else:
            plane_lo[0:L, 0:L] = spins_local[0:L, 0:L, 1]  # Publish the updated first owned plane.
            plane_hi[0:L, 0:L] = spins_local[0:L, 0:L, local_nz]  # Publish the updated last owned plane.
            sync
            spins_local[0:L, 0:L, 0] = plane_hi[0:L, 0:L]{down_img}  # Receive the lower ghost plane.
            spins_local[0:L, 0:L, local_nz + 1] = plane_lo[0:L, 0:L]{up_img}  # Receive the upper ghost plane.
            sync
        glauber_half_sweep_local(spins_local, L, local_nz, z_start, beta, J, base_seed, n_therm + meas_step, 1)

        if meas_step % meas_interval == 0:
            if np == 1:
                spins_local[0:L, 0:L, 0] = spins_local[0:L, 0:L, local_nz]  # Periodic lower ghost from the local last plane.
                spins_local[0:L, 0:L, local_nz + 1] = spins_local[0:L, 0:L, 1]  # Periodic upper ghost from the local first plane.
            else:
                plane_lo[0:L, 0:L] = spins_local[0:L, 0:L, 1]  # Publish the updated first owned plane.
                plane_hi[0:L, 0:L] = spins_local[0:L, 0:L, local_nz]  # Publish the updated last owned plane.
                sync
                spins_local[0:L, 0:L, 0] = plane_hi[0:L, 0:L]{down_img}  # Receive the lower ghost plane.
                spins_local[0:L, 0:L, local_nz + 1] = plane_lo[0:L, 0:L]{up_img}  # Receive the upper ghost plane.
                sync

            local_m_sum = local_magnetization_sum(spins_local, L, local_nz)  # Reduce the owned magnetization.
            local_bonds = local_bond_sum(spins_local, L, local_nz)  # Reduce the owned bond energy.

            reduce_buffer[0] = 1.0 * local_m_sum  # Publish the local magnetization sum.
            reduce_buffer[1] = 1.0 * local_bonds  # Publish the local bond sum.
            co_sum(reduce_buffer)  # Sum the observables across all images.

            if me == 0:
                m_abs = abs(reduce_buffer[0]) / n_sites  # Convert the global magnetization sum into |m| / N.
                e = -J * reduce_buffer[1] / n_sites  # Convert the global bond sum into the energy density.
                m2 = m_abs * m_abs  # Cache the second magnetization moment.
                sum_abs_m += m_abs  # Accumulate |m|.
                sum_m2 += m2  # Accumulate m^2.
                sum_m4 += m2 * m2  # Accumulate m^4.
                sum_e += e  # Accumulate e.
                sum_e2 += e * e  # Accumulate e^2.
                meas_count += 1  # Count the accepted measurement sample.

    if me == 0:
        if meas_count <= 0:
            print("3D Ising model - Glauber dynamics - coarray slabs - no measurements")  # Guard against degenerate runs.
        else:
            mean_abs_m = sum_abs_m / meas_count  # Convert the running sums into means.
            mean_m2 = sum_m2 / meas_count  # Convert the running sums into means.
            mean_m4 = sum_m4 / meas_count  # Convert the running sums into means.
            mean_e = sum_e / meas_count  # Convert the running sums into means.
            mean_e2 = sum_e2 / meas_count  # Convert the running sums into means.

            print("3D Ising model - Glauber dynamics - coarray slabs - L=", L, "T=", T)  # Match the benchmark summary.
            print("Images:", np, "Lattice:", L, "^3 =", L * L * L, "spins")  # Echo the distributed benchmark size.
            print("<|m|>:", mean_abs_m)  # Report the order parameter estimate.
            print("chi:", n_sites * beta * (mean_m2 - mean_abs_m * mean_abs_m))  # Report the susceptibility estimate.
            print("C:", n_sites * beta * beta * (mean_e2 - mean_e * mean_e))  # Report the specific heat estimate.
            print("U_4:", binder_cumulant(mean_m2, mean_m4))  # Report the Binder cumulant estimate.

def main():
    L: int = 256  # Match the current Python benchmark's lattice size.
    J: float = 1.0  # Ferromagnetic coupling.
    n_therm: int = 200  # Thermalisation sweeps discarded before sampling.
    n_meas: int = 500  # Number of post-thermalisation sweeps.
    meas_interval: int = 5  # Keep one sample every few sweeps.
    base_seed: int = 42  # Fixed seed for reproducible benchmark output.
    T: float = 0.0  # Current temperature in the benchmark sweep.

    for temp_index in range(2):
        if temp_index == 0:
            T = 2.0  # Ordered phase run.
        else:
            T = 6.0  # Disordered phase run.
        run_ising_coarray(L, T, J, n_therm, n_meas, meas_interval, base_seed)

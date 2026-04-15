# Serial FortScript port of benchmarks/ising_glauber.py.
# Uses checkerboard Glauber sweeps on a 3D periodic lattice.

struct IsingResult:
    mean_abs_m: float  # Mean absolute magnetization per site.
    chi: float  # Magnetic susceptibility estimate.
    heat_capacity: float  # Specific heat estimate.
    binder: float  # Binder cumulant.
    mag: array[float, :]  # Absolute magnetization history used for plotting.

def park_miller_next(seed: int) -> int:
    i4_huge: int = 2147483647  # Same modulus used in the MD benchmarks.
    q: int = 0  # Quotient for the Park-Miller recurrence.

    q = seed / 127773  # Split the state to avoid overflow in the recurrence.
    seed = 16807 * (seed - q * 127773) - q * 2836  # Advance the RNG state.
    seed = seed % i4_huge  # Keep the state inside the valid range.
    if seed <= 0:
        seed += i4_huge  # Repair the non-positive corner case.
    return seed

def init_spins(L: int, hot: bool, spins: array[int, :, :, :], seed: int) -> int:
    u: float = 0.0  # Uniform random number in [0, 1).

    for iz in range(L):
        for iy in range(L):
            for ix in range(L):
                if hot:
                    seed = park_miller_next(seed)  # Draw the next random state.
                    u = seed * 4.656612875E-10  # Map the integer state into [0, 1).
                    if u < 0.5:
                        spins[ix, iy, iz] = -1  # Random down spin.
                    else:
                        spins[ix, iy, iz] = 1  # Random up spin.
                else:
                    spins[ix, iy, iz] = 1  # Cold start below the critical point.
    return seed

def glauber_sweep(spins: array[int, :, :, :], L: int, beta: float, J: float, seed: int) -> int:
    phase: int = 0  # Checkerboard parity for the current half-sweep.
    ix: int = 0  # x index
    iy: int = 0  # y index
    iz: int = 0  # z index
    ip: int = 0  # Wrapped +x neighbour
    im: int = 0  # Wrapped -x neighbour
    jp: int = 0  # Wrapped +y neighbour
    jm: int = 0  # Wrapped -y neighbour
    kp: int = 0  # Wrapped +z neighbour
    km: int = 0  # Wrapped -z neighbour
    spin: int = 0  # Current site spin.
    h: int = 0  # Local field from the six neighbours.
    arg: float = 0.0  # Glauber logistic argument.
    accept: float = 0.0  # Heat-bath acceptance probability.
    z: float = 0.0  # Uniform random number for the update test.

    for phase in range(2):
        for iz in range(L):
            kp = iz + 1  # Candidate +z neighbour.
            if kp == L:
                kp = 0  # Wrap across the periodic boundary.
            km = iz - 1  # Candidate -z neighbour.
            if km < 0:
                km = L - 1  # Wrap across the periodic boundary.

            for iy in range(L):
                jp = iy + 1  # Candidate +y neighbour.
                if jp == L:
                    jp = 0  # Wrap across the periodic boundary.
                jm = iy - 1  # Candidate -y neighbour.
                if jm < 0:
                    jm = L - 1  # Wrap across the periodic boundary.

                for ix in range(L):
                    if (ix + iy + iz) % 2 == phase:
                        ip = ix + 1  # Candidate +x neighbour.
                        if ip == L:
                            ip = 0  # Wrap across the periodic boundary.
                        im = ix - 1  # Candidate -x neighbour.
                        if im < 0:
                            im = L - 1  # Wrap across the periodic boundary.

                        spin = spins[ix, iy, iz]  # Cache the current spin value.
                        h = spins[ip, iy, iz] + spins[im, iy, iz]  # x neighbours
                        h += spins[ix, jp, iz] + spins[ix, jm, iz]  # y neighbours
                        h += spins[ix, iy, kp] + spins[ix, iy, km]  # z neighbours

                        arg = 2.0 * J * beta * spin * h  # Local field form of DeltaE / T.
                        accept = 1.0 / (1.0 + exp(arg))  # Glauber heat-bath probability.

                        seed = park_miller_next(seed)  # Draw the update variate.
                        z = seed * 4.656612875E-10  # Map the state into [0, 1).
                        if accept > z:
                            spins[ix, iy, iz] = -spin  # Flip the spin when the move is accepted.
    return seed

def abs_magnetization_per_site(spins: array[int, :, :, :], L: int) -> float:
    m_sum: int = 0  # Total magnetization over the whole lattice.
    n_sites: int = L * L * L  # Number of spins in the lattice.

    for iz in range(L):
        for iy in range(L):
            for ix in range(L):
                m_sum += spins[ix, iy, iz]  # Accumulate the signed magnetization.

    if m_sum < 0:
        m_sum = -m_sum  # Take the absolute magnetization for the finite system.
    return 1.0 * m_sum / n_sites

def energy_per_site(spins: array[int, :, :, :], L: int, J: float) -> float:
    bond_sum: int = 0  # Sum each positive-direction bond exactly once.
    n_sites: int = L * L * L  # Number of spins in the lattice.
    ip: int = 0  # Wrapped +x neighbour
    jp: int = 0  # Wrapped +y neighbour
    kp: int = 0  # Wrapped +z neighbour

    for iz in range(L):
        kp = iz + 1  # Candidate +z neighbour.
        if kp == L:
            kp = 0  # Wrap across the periodic boundary.

        for iy in range(L):
            jp = iy + 1  # Candidate +y neighbour.
            if jp == L:
                jp = 0  # Wrap across the periodic boundary.

            for ix in range(L):
                ip = ix + 1  # Candidate +x neighbour.
                if ip == L:
                    ip = 0  # Wrap across the periodic boundary.

                bond_sum += spins[ix, iy, iz] * spins[ip, iy, iz]  # +x bond
                bond_sum += spins[ix, iy, iz] * spins[ix, jp, iz]  # +y bond
                bond_sum += spins[ix, iy, iz] * spins[ix, iy, kp]  # +z bond

    return -J * bond_sum / n_sites

def binder_cumulant(mean_m2: float, mean_m4: float) -> float:
    if mean_m2 <= 0.0:
        return 0.0  # Avoid a zero divide in the disordered corner case.
    return 1.0 - mean_m4 / (3.0 * mean_m2 * mean_m2)

def run_ising(L: int, T: float, J: float, n_therm: int, n_meas: int,
              meas_interval: int, seed0: int) -> IsingResult:
    result: IsingResult
    spins: array[int, :, :, :]  # 3D spin lattice with values +/-1.
    beta: float = 1.0 / T  # Inverse temperature in units with k_B = 1.
    seed: int = seed0  # Mutable RNG state carried across the whole run.
    hot: bool = False  # Choose the initial condition from the temperature.
    n_sites: int = L * L * L  # Number of spins used in thermodynamic factors.
    meas_count: int = 0  # Number of actual stored measurements.
    m_abs: float = 0.0  # Instantaneous absolute magnetization per site.
    e: float = 0.0  # Instantaneous energy per site.
    m2: float = 0.0  # Second magnetization moment.
    mean_abs_m: float = 0.0  # Sample mean of |m|.
    mean_m2: float = 0.0  # Sample mean of m^2 built from |m|.
    mean_m4: float = 0.0  # Sample mean of m^4 built from |m|.
    mean_e: float = 0.0  # Sample mean of e.
    mean_e2: float = 0.0  # Sample mean of e^2.
    sum_abs_m: float = 0.0  # Running sum for |m|.
    sum_m2: float = 0.0  # Running sum for m^2.
    sum_m4: float = 0.0  # Running sum for m^4.
    sum_e: float = 0.0  # Running sum for e.
    sum_e2: float = 0.0  # Running sum for e^2.
    mags: array[float, :]  # Stored |m| measurements for plotting.

    allocate(spins, L, L, L)
    allocate(mags, n_meas / meas_interval + 1)

    hot = T > J * 4.5115232  # Cold start below T_c, hot start above.
    seed = init_spins(L, hot, spins, seed)

    for therm_step in range(n_therm):
        seed = glauber_sweep(spins, L, beta, J, seed)  # Discard thermalisation sweeps.

    for meas_step in range(n_meas):
        seed = glauber_sweep(spins, L, beta, J, seed)  # Advance one full lattice sweep.
        if meas_step % meas_interval == 0:
            m_abs = abs_magnetization_per_site(spins, L)  # Measure |m| / N.
            e = energy_per_site(spins, L, J)  # Measure the energy density.
            m2 = m_abs * m_abs  # Cache the second moment.
            sum_abs_m += m_abs  # Accumulate |m|.
            sum_m2 += m2  # Accumulate m^2.
            sum_m4 += m2 * m2  # Accumulate m^4.
            sum_e += e  # Accumulate e.
            sum_e2 += e * e  # Accumulate e^2.
            mags[meas_count] = m_abs  # Store the time trace for the output plot.
            meas_count += 1  # Count the accepted measurement sample.

    result.mean_abs_m = 0.0
    result.chi = 0.0
    result.heat_capacity = 0.0
    result.binder = 0.0
    result.mag = zeros(0)

    if meas_count <= 0:
        return result  # Keep the zeroed result for degenerate runs.

    mean_abs_m = sum_abs_m / meas_count  # Convert the running sums into means.
    mean_m2 = sum_m2 / meas_count  # Convert the running sums into means.
    mean_m4 = sum_m4 / meas_count  # Convert the running sums into means.
    mean_e = sum_e / meas_count  # Convert the running sums into means.
    mean_e2 = sum_e2 / meas_count  # Convert the running sums into means.

    result.mean_abs_m = mean_abs_m  # Report the order parameter estimate.
    result.chi = n_sites * beta * (mean_m2 - mean_abs_m * mean_abs_m)  # Fluctuation formula for chi.
    result.heat_capacity = n_sites * beta * beta * (mean_e2 - mean_e * mean_e)  # Fluctuation formula for C.
    result.binder = binder_cumulant(mean_m2, mean_m4)  # Dimensionless Binder ratio.
    result.mag = mags[:meas_count]  # Trim the plot trace to the exact number of samples.
    return result

def main():
    L: int = 256  # Match the current Python benchmark's lattice size.
    J: float = 1.0  # Ferromagnetic coupling.
    n_therm: int = 200  # Thermalisation sweeps discarded before sampling.
    n_meas: int = 500  # Number of post-thermalisation sweeps.
    meas_interval: int = 5  # Keep one sample every few sweeps.
    seed: int = 42  # Fixed seed for reproducible benchmark output.
    T: float = 0.0  # Current temperature in the benchmark sweep.
    result: IsingResult
    sweep: array[float, :]  # Sweep index vector for the magnetization plot.

    for temp_index in range(2):
        if temp_index == 0:
            T = 2.0  # Ordered phase run.
        else:
            T = 6.0  # Disordered phase run.

        result = run_ising(L, T, J, n_therm, n_meas, meas_interval, seed)
        sweep = linspace(0.0, size(result.mag) - 1.0, size(result.mag))

        print("3D Ising model - Glauber dynamics - L=", L, "T=", T)  # Match the Python benchmark summary.
        print("Lattice:", L, "^3 =", L * L * L, "spins")  # Echo the lattice size.
        print("<|m|>:", result.mean_abs_m)  # Report the order parameter estimate.
        print("chi:", result.chi)  # Report the susceptibility estimate.
        print("C:", result.heat_capacity)  # Report the specific heat estimate.
        print("U_4:", result.binder)  # Report the Binder cumulant estimate.

        if temp_index == 0:
            plot(sweep, result.mag, "ising_sweep_vs_m_L256_T2.png", "Ising |m| vs sweep", "sweep", "|m|")  # Save the ordered-phase trace.
        else:
            plot(sweep, result.mag, "ising_sweep_vs_m_L256_T6.png", "Ising |m| vs sweep", "sweep", "|m|")  # Save the disordered-phase trace.

# do concurrent FortScript port of benchmarks/ising_glauber.py.
# Uses checkerboard Glauber sweeps on a 3D periodic lattice.
# The sweep compute kernel and the measurement reductions are marked with @par
# (do concurrent), which is the construct this benchmark measures. Random numbers
# are generated separately in an @omp loop (one prand stream per thread) into a
# per-site field that the do concurrent kernel then reads, because the stateful
# prand generator cannot be called from a do concurrent loop.

import support.random

struct IsingResult:
    mean_abs_m: float  # Mean absolute magnetization per site.
    chi: float  # Magnetic susceptibility estimate.
    heat_capacity: float  # Specific heat estimate.
    binder: float  # Binder cumulant.
    mag: array[float, :]  # Absolute magnetization history used for plotting.

def ising_stream_seed(base_seed: int, sweep_id: int, phase: int) -> int:
    sweep_mix: int = 65537  # Prime used to separate sweep streams.
    phase_mix: int = 17  # Prime used to separate checkerboard phases.

    return base_seed + sweep_mix * (sweep_id + 1) + phase_mix * (phase + 1)

def init_spins(L: int, hot: bool, spins: array[int, :, :, :]):
    u: float = 0.0  # Uniform random number in [0, 1).

    for iz in range(L):
        for iy in range(L):
            for ix in range(L):
                if hot:
                    u = prand_uniform()  # Serial prand draw in [0, 1).
                    if u < 0.5:
                        spins[ix, iy, iz] = -1  # Random down spin.
                    else:
                        spins[ix, iy, iz] = 1  # Random up spin.
                else:
                    spins[ix, iy, iz] = 1  # Cold start.

def fill_rng_field(rng_field: array[float, :, :, :], L: int,
                   base_seed: int, sweep_id: int, phase: int):
    # Generate the per-site random numbers for one half-sweep in a separate @omp
    # loop. prand is a stateful generator and cannot be called from a @par
    # (do concurrent) loop, so the random field is produced here first with
    # OpenMP (one prand stream per thread) and then read by the do concurrent
    # compute kernel. This keeps the benchmark's compute loop on do concurrent,
    # which is the construct this benchmark exists to measure. The per-thread
    # stream mapping means the draw order depends on the thread count.
    prand_seed_parallel(ising_stream_seed(base_seed, sweep_id, phase))
    @omp
    for iz in range(L):
        for iy in range(L):
            for ix in range(L):
                rng_field[ix, iy, iz] = prand_uniform_thread()  # Per-thread prand draw.

def glauber_phase_sweep(spins_in: array[int, :, :, :],
                        spins_out: array[int, :, :, :],
                        rng_field: array[float, :, :, :],
                        L: int, beta: float, J: float,
                        base_seed: int, sweep_id: int, phase: int):
    ip: int = 0  # Wrapped +x neighbour.
    im: int = 0  # Wrapped -x neighbour.
    jp: int = 0  # Wrapped +y neighbour.
    jm: int = 0  # Wrapped -y neighbour.
    kp: int = 0  # Wrapped +z neighbour.
    km: int = 0  # Wrapped -z neighbour.
    spin: int = 0  # Current site spin.
    h: int = 0  # Local field from the six neighbours.
    arg: float = 0.0  # Glauber logistic argument.
    accept: float = 0.0  # Heat-bath acceptance probability.
    z: float = 0.0  # Uniform random number for the update test.

    # Precompute the per-site random field with OpenMP (see fill_rng_field).
    fill_rng_field(rng_field, L, base_seed, sweep_id, phase)

    # Checkerboard Glauber update on do concurrent (@par), the construct this
    # benchmark measures. The outer z-plane loop is parallelized; inner iy, ix
    # loops run serially within each parallel iteration so gfortran sees unique
    # write targets. The per-site random number is read from the precomputed
    # rng_field instead of being drawn inside the loop.
    @par
    @local(ip)
    @local(im)
    @local(jp)
    @local(jm)
    @local(kp)
    @local(km)
    @local(spin)
    @local(h)
    @local(arg)
    @local(accept)
    @local(z)
    for iz in range(L):
        kp = (iz + 1) % L  # +z neighbour with periodic wrap.
        km = (iz - 1 + L) % L  # -z neighbour with periodic wrap.
        for iy in range(L):
            jp = (iy + 1) % L  # +y neighbour with periodic wrap.
            jm = (iy - 1 + L) % L  # -y neighbour with periodic wrap.
            for ix in range(L):
                spin = spins_in[ix, iy, iz]  # Read the current spin.
                spins_out[ix, iy, iz] = spin  # Default: copy unchanged.
                if (ix + iy + iz) % 2 == phase:
                    ip = (ix + 1) % L  # +x neighbour with periodic wrap.
                    im = (ix - 1 + L) % L  # -x neighbour with periodic wrap.

                    h = spins_in[ip, iy, iz] + spins_in[im, iy, iz]  # x neighbours.
                    h += spins_in[ix, jp, iz] + spins_in[ix, jm, iz]  # y neighbours.
                    h += spins_in[ix, iy, kp] + spins_in[ix, iy, km]  # z neighbours.

                    arg = 2.0 * J * beta * spin * h  # DeltaE / T.
                    accept = 1.0 / (1.0 + exp(arg))  # Glauber probability.
                    z = rng_field[ix, iy, iz]  # Precomputed per-site random number.
                    if accept > z:
                        spins_out[ix, iy, iz] = -spin  # Flip accepted.

def abs_magnetization_per_site(spins: array[int, :, :, :], L: int) -> float:
    m_sum: int = 0  # Total signed magnetization.
    n_sites: int = L * L * L  # Number of spins.

    @par
    @reduce(add: m_sum)
    for iz in range(L):
        for iy in range(L):
            for ix in range(L):
                m_sum += spins[ix, iy, iz]  # Accumulate magnetization.

    if m_sum < 0:
        m_sum = -m_sum  # Absolute value.
    return 1.0 * m_sum / n_sites

def energy_per_site(spins: array[int, :, :, :], L: int, J: float) -> float:
    bond_sum: int = 0  # Sum each positive-direction bond once.
    n_sites: int = L * L * L  # Number of spins.
    ip: int = 0  # Wrapped +x neighbour.
    jp: int = 0  # Wrapped +y neighbour.
    kp: int = 0  # Wrapped +z neighbour.

    @par
    @local(ip)
    @local(jp)
    @local(kp)
    @reduce(add: bond_sum)
    for iz in range(L):
        kp = (iz + 1) % L  # +z wrap.
        for iy in range(L):
            jp = (iy + 1) % L  # +y wrap.
            for ix in range(L):
                ip = (ix + 1) % L  # +x wrap.
                bond_sum += spins[ix, iy, iz] * spins[ip, iy, iz]  # +x bond.
                bond_sum += spins[ix, iy, iz] * spins[ix, jp, iz]  # +y bond.
                bond_sum += spins[ix, iy, iz] * spins[ix, iy, kp]  # +z bond.

    return -J * bond_sum / n_sites

def binder_cumulant(mean_m2: float, mean_m4: float) -> float:
    if mean_m2 <= 0.0:
        return 0.0  # Avoid zero divide.
    return 1.0 - mean_m4 / (3.0 * mean_m2 * mean_m2)

def run_ising(L: int, T: float, J: float, n_therm: int, n_meas: int,
              meas_interval: int, seed0: int) -> IsingResult:
    result: IsingResult
    spins: array[int, :, :, :]  # 3D spin lattice +/-1.
    spins_next: array[int, :, :, :]  # Double buffer for parallel sweep output.
    rng_field: array[float, :, :, :]  # Per-site random numbers, refilled per half-sweep.
    beta: float = 1.0 / T  # Inverse temperature.
    base_seed: int = seed0  # Seed for initialization and per-site RNG.
    hot: bool = False  # Initial condition selector.
    n_sites: int = L * L * L  # Total spin count.
    meas_count: int = 0  # Number of stored measurements.
    m_abs: float = 0.0  # Instantaneous |m|.
    e: float = 0.0  # Instantaneous energy per site.
    m2: float = 0.0  # Second magnetization moment.
    mean_abs_m: float = 0.0  # Sample mean of |m|.
    mean_m2: float = 0.0  # Sample mean of m^2.
    mean_m4: float = 0.0  # Sample mean of m^4.
    mean_e: float = 0.0  # Sample mean of e.
    mean_e2: float = 0.0  # Sample mean of e^2.
    sum_abs_m: float = 0.0  # Running sum for |m|.
    sum_m2: float = 0.0  # Running sum for m^2.
    sum_m4: float = 0.0  # Running sum for m^4.
    sum_e: float = 0.0  # Running sum for e.
    sum_e2: float = 0.0  # Running sum for e^2.
    mags: array[float, :]  # Stored measurements for plotting.

    allocate(spins, L, L, L)
    allocate(spins_next, L, L, L)
    allocate(rng_field, L, L, L)
    allocate(mags, n_meas / meas_interval + 1)

    seed(seed0)  # Seed the serial prand stream used by init_spins.
    hot = T > J * 4.5115232  # Cold start below T_c, hot above.
    init_spins(L, hot, spins)

    # Thermalisation: discard sweeps to reach equilibrium.
    for therm_step in range(n_therm):
        glauber_phase_sweep(spins, spins_next, rng_field, L, beta, J, base_seed, therm_step, 0)
        spins = spins_next  # Publish the black half-sweep.
        glauber_phase_sweep(spins, spins_next, rng_field, L, beta, J, base_seed, therm_step, 1)
        spins = spins_next  # Publish the white half-sweep.

    # Measurement phase: sample observables periodically.
    for meas_step in range(n_meas):
        glauber_phase_sweep(spins, spins_next, rng_field, L, beta, J, base_seed, n_therm + meas_step, 0)
        spins = spins_next  # Publish the black half-sweep.
        glauber_phase_sweep(spins, spins_next, rng_field, L, beta, J, base_seed, n_therm + meas_step, 1)
        spins = spins_next  # Publish the white half-sweep.
        if meas_step % meas_interval == 0:
            m_abs = abs_magnetization_per_site(spins, L)  # Measure |m| / N.
            e = energy_per_site(spins, L, J)  # Measure energy density.
            m2 = m_abs * m_abs  # Cache second moment.
            sum_abs_m += m_abs  # Accumulate |m|.
            sum_m2 += m2  # Accumulate m^2.
            sum_m4 += m2 * m2  # Accumulate m^4.
            sum_e += e  # Accumulate e.
            sum_e2 += e * e  # Accumulate e^2.
            mags[meas_count] = m_abs  # Store for plotting.
            meas_count += 1  # Count the sample.

    result.mean_abs_m = 0.0
    result.chi = 0.0
    result.heat_capacity = 0.0
    result.binder = 0.0
    result.mag = zeros(0)

    if meas_count <= 0:
        return result  # Zeroed result for degenerate runs.

    mean_abs_m = sum_abs_m / meas_count  # Convert sums to means.
    mean_m2 = sum_m2 / meas_count
    mean_m4 = sum_m4 / meas_count
    mean_e = sum_e / meas_count
    mean_e2 = sum_e2 / meas_count

    result.mean_abs_m = mean_abs_m  # Order parameter.
    result.chi = n_sites * beta * (mean_m2 - mean_abs_m * mean_abs_m)  # Susceptibility.
    result.heat_capacity = n_sites * beta * beta * (mean_e2 - mean_e * mean_e)  # Specific heat.
    result.binder = binder_cumulant(mean_m2, mean_m4)  # Binder cumulant.
    result.mag = mags[:meas_count]  # Trim to exact sample count.
    return result

def main():
    L: int = 512  # Match the Python benchmark lattice size.
    J: float = 1.0  # Ferromagnetic coupling.
    n_therm: int = 200  # Thermalisation sweeps.
    n_meas: int = 500  # Post-thermalisation sweeps.
    meas_interval: int = 5  # Sample every few sweeps.
    rng_seed: int = 42  # Fixed seed for reproducibility.
    T: float = 0.0  # Current temperature.
    result: IsingResult
    sweep: array[float, :]  # Sweep index vector for the plot.

    for temp_index in range(2):
        if temp_index == 0:
            T = 2.0  # Ordered phase.
        else:
            T = 6.0  # Disordered phase.

        result = run_ising(L, T, J, n_therm, n_meas, meas_interval, rng_seed)
        sweep = linspace(0.0, size(result.mag) - 1.0, size(result.mag))

        print("3D Ising model - Glauber dynamics - do concurrent - L=", L, "T=", T)
        print("Lattice:", L, "^3 =", L * L * L, "spins")
        print("<|m|>:", result.mean_abs_m)
        print("chi:", result.chi)
        print("C:", result.heat_capacity)
        print("U_4:", result.binder)

        if temp_index == 0:
            plot(sweep, result.mag, "ising_sweep_vs_m_do_concurrent_L256_T2.png", "Ising |m| vs sweep", "sweep", "|m|")
        else:
            plot(sweep, result.mag, "ising_sweep_vs_m_do_concurrent_L256_T6.png", "Ising |m| vs sweep", "sweep", "|m|")

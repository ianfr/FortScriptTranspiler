"""
Ising Model with Glauber (Heat Bath) Dynamics
==============================================
Serial NumPy implementation.

References (Herrmann & Bottcher, Computational Statistical Physics, 2021):
  - Sec. 3.2   : Ising model definition, Hamiltonian (eq. 3.20), order parameter
  - Sec. 3.2.1 : Spontaneous magnetization M_S(T) as order parameter (eq. 3.22)
  - Sec. 3.2.2 : Response functions - susceptibility chi and specific heat C
  - Sec. 4.6   : Glauber (heat bath) dynamics, acceptance probability A_G (eq. 4.36)
  - Sec. 4.6   : Local-field formulation A_G(sigma_i) = exp(-2Jsigma_i h_i / k_BT)
                 / (1 + exp(-2Jsigma_i h_i / k_BT))  (eq. 4.41)
  - Sec. 4.6   : Update rule sigma_i(tau+1) = -sigma_i(tau) * sign(A_G(sigma_i) - z)  (eq. 4.42)
  - Sec. 4.9   : Periodic boundary conditions
  - Sec. 5.3   : Finite-size scaling setup (multiple L values)
  - Sec. 5.4   : Binder cumulant U_4 = 1 - <m^4> / (3 <m^2>^2)
"""

import numpy as np
import matplotlib.pyplot as plt

# ---------------------------------------------------------------------------
# Lattice initialisation
# ---------------------------------------------------------------------------

def init_spins(L: int, rng: np.random.Generator, hot: bool = True) -> np.ndarray:
    """
    Return an (L, L, L) int32 lattice of spins +/-1.

    hot=True  -> disordered (T -> inf) start: spins drawn uniformly from {-1, +1}.
    hot=False -> ordered   (T -> 0) start: all spins = +1.

    A cold start is preferred near or below T_c to avoid metastability.
    3D Ising critical temperature: k_B T_c / J ~= 4.5115232 (Ref. Sec. 3.2).
    """
    if hot:
        return rng.choice(np.array([-1, 1], dtype=np.int32), size=(L, L, L))
    return np.ones((L, L, L), dtype=np.int32)


# ---------------------------------------------------------------------------
# Local field and Glauber acceptance probability
# ---------------------------------------------------------------------------

def local_field(spins: np.ndarray) -> np.ndarray:
    """
    Compute h_i = sum_{<i,j>} sigma_j for every site i simultaneously,
    where the sum runs over the 6 nearest neighbours on the 3D cubic lattice.

    Periodic boundary conditions are applied via np.roll (Ref. Sec. 4.9).
    The result is an integer array with values in {-6, -4, -2, 0, 2, 4, 6}.

    This is the vectorised equivalent of iterating over all sites and
    summing the four (2D) or six (3D) neighbours explicitly.
    """
    # Ref. Sec. 3.2: H = -J sum_{<i,j>} sigma_i sigma_j  -> local field h_i drives DeltaE.
    h = (
        np.roll(spins,  1, axis=0) + np.roll(spins, -1, axis=0)   # +/-x
      + np.roll(spins,  1, axis=1) + np.roll(spins, -1, axis=1)   # +/-y
      + np.roll(spins,  1, axis=2) + np.roll(spins, -1, axis=2)   # +/-z
    )
    return h   # shape (L, L, L)


# ---------------------------------------------------------------------------
# Checkerboard (red-black) decomposition
# ---------------------------------------------------------------------------

def checkerboard_masks(L: int):
    """
    Return boolean masks for the two sublattices of the 3D cubic lattice.

    Sites with (i+j+k) even form the 'black' sublattice; odd sites form 'white'.
    Within one sublattice, no two sites are nearest neighbours, so all sites
    can be updated simultaneously without introducing update-order bias.

    (Ref. Sec. 10.2 Vectorisation, Sec. 10.3 Domain Decomposition).
    """
    i, j, k = np.mgrid[0:L, 0:L, 0:L]
    black = ((i + j + k) % 2 == 0)
    white = ~black
    return black, white


# ---------------------------------------------------------------------------
# Single Glauber sweep
# ---------------------------------------------------------------------------

def glauber_sweep(
    spins: np.ndarray,
    beta: float,
    J: float,
    black_mask: np.ndarray,
    white_mask: np.ndarray,
    rng: np.random.Generator,
) -> np.ndarray:
    """
    One full lattice sweep using Glauber (heat bath) dynamics.

    Glauber acceptance probability (Ref. Sec. 4.6, eq. 4.36):

        A_G(X -> Y) = exp(-DeltaE / k_B T) / (1 + exp(-DeltaE / k_B T))

    For the Ising model, DeltaE = 2 J sigma_i h_i, giving the local form
    (Ref. Sec. 4.6, eq. 4.41):

        A_G(sigma_i) = exp(-2 J sigma_i h_i / k_B T)
                       / (1 + exp(-2 J sigma_i h_i / k_B T))

    The update rule is (Ref. Sec. 4.6, eq. 4.42):

        sigma_i(tau+1) = -sigma_i(tau) * sign(A_G(sigma_i) - z),  z in (0,1) uniform.


    The sweep is split into two half-sweeps over the checkerboard sublattices
    so that all updated sites are independent within each half-sweep -
    this is the vectorised analogue of a sequential site loop.
    """
    for mask in (black_mask, white_mask):
        # --- local field h_i = sum_{neighbours j} sigma_j  (Ref. eq. 4.41) ---
        h = local_field(spins)          # (L,L,L) int array

        # --- Glauber acceptance probability A_G for each masked site ---
        # A_G = sigmoid(-2 J sigma_i h_i beta)
        # Written as sigmoid to avoid exp overflow for large arguments.
        # Numerically: A_G = 1 / (1 + exp(+2 J beta sigma_i h_i))
        arg = 2.0 * J * beta * spins * h          # (L,L,L) float
        A_G = 1.0 / (1.0 + np.exp(arg))           # eq. 4.36 / 4.41

        # --- Uniform random numbers z in (0, 1) for the update rule ---
        z = rng.random(spins.shape)                # eq. 4.42

        # --- Apply update: flip if A_G > z, i.e. sign(A_G - z) = +1 ---
        # sigma_i -> -sigma_i  when A_G > z  (spin is flipped)
        # sigma_i -> +sigma_i  when A_G < z  (spin is kept)
        flip = mask & (A_G > z)
        spins = np.where(flip, -spins, spins)

    return spins


# ---------------------------------------------------------------------------
# Observables
# ---------------------------------------------------------------------------

def magnetization(spins: np.ndarray) -> float:
    """
    Instantaneous magnetization per site m = (1/N) sum_i sigma_i.

    The order parameter is the spontaneous magnetization M_S(T) = lim_{H->0+}
    <m> (Ref. Sec. 3.2.1, eq. 3.22).  We use |m| to avoid the sign ambiguity
    that would cause <m> -> 0 even in the ordered phase.
    """
    return float(spins.mean())


def energy_per_site(spins: np.ndarray, J: float) -> float:
    """
    Energy per site: e = H/N = -(J/N) sum_{<i,j>} sigma_i sigma_j.

    Uses the same rolling-neighbour trick as local_field() to compute
    sum_{<i,j>} sigma_i sigma_j without double-counting (divide by 2).

    The Hamiltonian is (Ref. Sec. 3.2, eq. 3.20, H=0 case):
        H({sigma}) = -J sum_{<i,j>} sigma_i sigma_j
    """
    # Sum sigma_i * sigma_j over all directed bonds, then divide by 2 for undirected.
    bond_sum = (
        (spins * np.roll(spins, 1, axis=0)).sum()
      + (spins * np.roll(spins, 1, axis=1)).sum()
      + (spins * np.roll(spins, 1, axis=2)).sum()
    )
    N = spins.size
    return float(-J * bond_sum / N)


def binder_cumulant(m2_acc: float, m4_acc: float) -> float:
    """
    Binder cumulant U_4 = 1 - <m^4> / (3 <m^2>^2).

    U_4 -> 2/3 in the ordered phase, -> 0 in the disordered phase,
    and the curves for different L cross at T_c, providing a
    size-independent estimate of the critical temperature (Ref. Sec. 5.4).
    """
    return 1.0 - m4_acc / (3.0 * m2_acc**2) if m2_acc > 0 else 0.0


# ---------------------------------------------------------------------------
# Main simulation loop
# ---------------------------------------------------------------------------

def run(
    L: int = 32,
    T: float = 4.5115232,   # 3D Ising T_c in units J/k_B  (Ref. Sec. 3.2)
    J: float = 1.0,
    n_therm: int = 500,      # thermalisation sweeps
    n_meas: int = 1000,      # measurement sweeps
    meas_interval: int = 5,  # sweep interval between measurements
                             # (decorrelation; Ref. Sec. 5.2)
    seed: int = 42,
) -> dict:
    """
    Run a full Glauber MC simulation and return measured observables.

    Thermalisation discards n_therm sweeps; measurements are taken every
    meas_interval sweeps to reduce autocorrelation (Ref. Sec. 5.1-5.2).

    Returns a dict with arrays:
        mag      : instantaneous |m| per measurement
        energy   : instantaneous e per measurement
        m2, m4   : squared and fourth powers of m (for Binder cumulant)
    and scalars:
        mean_|m|, susceptibility chi, specific heat C, binder U_4.
    """
    beta = 1.0 / T
    rng  = np.random.default_rng(seed)

    # Initialise: cold start below T_c, hot start above (Ref. Sec. 3.2)
    hot  = (T > J * 4.5115232)
    spins = init_spins(L, rng, hot=hot)

    black_mask, white_mask = checkerboard_masks(L)
    N = L**3

    # --- Thermalisation ---
    for _ in range(n_therm):
        spins = glauber_sweep(spins, beta, J, black_mask, white_mask, rng)

    # --- Measurement ---
    mags, energies, m2s, m4s = [], [], [], []

    for t in range(n_meas):
        spins = glauber_sweep(spins, beta, J, black_mask, white_mask, rng)
        if t % meas_interval == 0:
            m = abs(magnetization(spins))
            e = energy_per_site(spins, J)
            mags.append(m)
            energies.append(e)
            m2s.append(m**2)
            m4s.append(m**4)

    mags     = np.array(mags)
    energies = np.array(energies)
    m2s      = np.array(m2s)
    m4s      = np.array(m4s)

    mean_m  = mags.mean()
    mean_m2 = m2s.mean()
    mean_m4 = m4s.mean()
    mean_e  = energies.mean()
    mean_e2 = (energies**2).mean()

    # Magnetic susceptibility chi = N beta (<m^2> - <|m|>^2)  (Ref. Sec. 3.2.2)
    chi = N * beta * (mean_m2 - mean_m**2)

    # Specific heat C = N beta^2 (<e^2> - <e>^2)             (Ref. Sec. 3.2.2)
    C   = N * beta**2 * (mean_e2 - mean_e**2)

    # Binder cumulant                                    (Ref. Sec. 5.4)
    U4  = binder_cumulant(mean_m2, mean_m4)

    return {
        "L": L, "T": T, "beta": beta,
        "mag":      mags,
        "energy":   energies,
        "mean_|m|": mean_m,
        "chi":      chi,
        "C":        C,
        "binder":   U4,
    }


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":

    # Use a big grid to show parallel speedups
    L = 256
    T_list = [2, 6] # Temperatures to run at

    for T in T_list:
        print(f"3D Ising model - Glauber dynamics - L={L}, T={T:.4f} (~T_c)")
        print(f"Lattice: {L}^3 = {L**3:,} spins")

        res = run(L=L, T=T, n_therm=200, n_meas=500, meas_interval=5)

        # At T = T_c = 4.5115232:
        # <m> -> 0
        # chi -> diverges
        # U4 -> 0.465 for 3D
        print(f"<|m|>     : {res['mean_|m|']:.4f}   (~1 for T < T_c ; ~0 for t > T_c)")
        print(f"chi       : {res['chi']:.2f}          (diverges at T_c)")
        print(f"C         : {res['C']:.4f}")
        print(f"U_4       : {res['binder']:.4f}       (~2/3 for T < T_c ; ~0 for t > T_c))")

        plt.figure()
        plt.plot(res["mag"])
        plt.xlabel("sweep")
        plt.ylabel("|m|")
        plt.savefig(f"ising_sweep_vs_m_L{L}_T{T}.png")
        plt.close()

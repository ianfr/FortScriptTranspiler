# 1D Heat diffusion with FortScript
# Demonstrates: structs, arrays of structs, @par, numpy-like ops

struct SimParams:
    dx: float
    dt: float
    alpha: float
    nx: int
    nsteps: int

def initialize(params: SimParams, u: array[float, 1000]):
    # Gaussian pulse initial condition
    for i in range(params.nx):
        x: float = (i - params.nx / 2) * params.dx
        u[i] = exp(-x * x / 0.1)

def diffusion_step(params: SimParams, u: array[float, 1000], u_new: array[float, 1000]):
    r: float = params.alpha * params.dt / (params.dx * params.dx)

    # Boundary conditions
    u_new[0] = 0.0
    u_new[params.nx - 1] = 0.0

    # Interior points - parallel
    @par
    for i in range(1, params.nx - 1):
        u_new[i] = u[i] + r * (u[i + 1] - 2.0 * u[i] + u[i - 1])

def compute_total_energy(n: int, u: array[float, 1000]) -> float:
    total: float = 0.0
    for i in range(n):
        total += u[i] * u[i]
    return total

def main():
    params: SimParams
    params.dx = 0.01
    params.dt = 0.00001
    params.alpha = 1.0
    params.nx = 200
    params.nsteps = 500

    u: array[float, 1000]
    u_new: array[float, 1000]

    initialize(params, u)

    e0: float = compute_total_energy(params.nx, u)
    print("Initial energy:", e0)

    for step in range(params.nsteps):
        diffusion_step(params, u, u_new)
        # Swap: copy u_new back to u
        @par
        for i in range(params.nx):
            u[i] = u_new[i]

    ef: float = compute_total_energy(params.nx, u)
    print("Final energy:", ef)
    print("Energy ratio:", ef / e0)

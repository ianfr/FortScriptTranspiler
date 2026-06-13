# Demonstration of support.random serial and parallel RNG helpers, backed by the
# prand library through support/prand_mod.f90.

import support.random

def main():
    n: int = 1000  # Number of serial samples.
    x: array[float, :]  # Uniform samples in [0, 1).
    y: array[float, :]  # Uniform samples in [-1, 1).
    z: array[float, :]  # Standard normal samples.
    grid: array[float, :, :]  # Per-thread parallel samples.
    i: int = 0
    j: int = 0

    allocate(x, n)
    allocate(y, n)
    allocate(z, n)
    allocate(grid, 16, 16)

    seed(42)  # Set the serial RNG stream.
    random_fill(x)  # Fill with uniform values.
    uniform_fill(-1.0, 1.0, y)  # Fill with scaled uniform values.
    normal_fill(z)  # Fill with standard normal values.

    # Parallel draws: one prand stream per OpenMP thread. prand_seed_parallel must
    # be called once before the @omp loop; prand_uniform_thread draws from the
    # calling thread's stream. The loop runs under @omp because prand is stateful
    # and cannot be called from a do concurrent (@par) loop.
    prand_seed_parallel(7)
    @omp
    for i in range(16):
        for j in range(16):
            grid[i, j] = prand_uniform_thread()  # Per-thread parallel draw.

    histogram(z, "random_demo_normal.png", "Normal samples", "x", "count", 30)
    print("uniform mean proxy", sum(x) / n)
    print("scaled mean proxy", sum(y) / n)
    print("normal mean proxy", sum(z) / n)
    print("parallel corner sample", grid[0, 0])

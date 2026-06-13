# Test support.random helpers backed by prand: seed, random_fill, uniform_fill,
# normal_fill, prand_uniform (serial), and prand_uniform_thread (per-thread,
# inside an @omp loop). Runs as a single process.

import support.random

def main():
    a: float = 0.0
    b: float = 0.0
    u: float = 0.0
    x: array[float, :]
    g: array[float, :, :]
    i: int = 0
    j: int = 0

    # prand_uniform stays inside [0, 1)
    seed(42)
    u = prand_uniform()
    if u < 0.0 or u >= 1.0:
        exit(1)

    # Reseeding with the same value reproduces the first draw
    seed(123)
    a = prand_uniform()
    seed(123)
    b = prand_uniform()
    if abs(a - b) > 1.0e-12:
        exit(1)

    # Different seeds should give different first draws here
    seed(123)
    a = prand_uniform()
    seed(124)
    b = prand_uniform()
    if abs(a - b) < 1.0e-12:
        exit(1)

    # Serial random_fill: every sample is in [0, 1)
    allocate(x, 100)
    seed(42)
    random_fill(x)
    for i in range(100):
        if x[i] < 0.0 or x[i] >= 1.0:
            exit(1)

    # uniform_fill scales samples into [low, high)
    uniform_fill(-2.0, 2.0, x)
    for i in range(100):
        if x[i] < -2.0 or x[i] >= 2.0:
            exit(1)

    # normal_fill produces finite samples (sanity: each equals itself)
    normal_fill(x)
    for i in range(100):
        if x[i] != x[i]:
            exit(1)              # NaN guard

    # Parallel per-thread draws stay inside [0, 1)
    allocate(g, 32, 32)
    prand_seed_parallel(99)
    @omp
    for i in range(32):
        for j in range(32):
            g[i, j] = prand_uniform_thread()
    for i in range(32):
        for j in range(32):
            if g[i, j] < 0.0 or g[i, j] >= 1.0:
                exit(1)

    print("test_random: all checks passed")

# FortScript random support library.
#
# Random number generation is backed by the prand C library
# (https://github.com/cheng-zhao/prand, MIT), wrapped in the hand-written
# Fortran module support/prand_mod.f90. The transpiler lowers the stubs below to
# calls into that module and emits `use prand_mod` for any program that imports
# this file.
#
# Serial draws use a single-stream generator. Parallel draws inside an @omp loop
# use one prand stream per OpenMP thread; call prand_seed_parallel once before the
# loop, then call prand_uniform_thread inside it. Because the streams are mapped
# to threads, the parallel draw order depends on the thread count, so @omp draws
# are not bit-reproducible across different thread counts.
#
# For coarray (SPMD) programs each image is a separate process with its own
# generator: seed every image (identically for a shared global sequence, or per
# image with seed(base + this_image() * k) for independent streams) and draw with
# prand_uniform.

def seed(s: int):
    pass  # The compiler lowers this stub to a prand serial-generator reseed.

def random_fill(x: array[float, :]):
    pass  # The compiler lowers this stub to a prand serial uniform fill.

def uniform_fill(low: float, high: float, x: array[float, :]):
    pass  # The compiler lowers this stub to a prand serial uniform fill plus scaling.

def prand_uniform() -> float:
    pass  # The compiler lowers this stub to one prand serial uniform draw.

def prand_seed_parallel(s: int):
    pass  # The compiler lowers this stub to a prand multi-stream init (one stream per OpenMP thread).

def prand_uniform_thread() -> float:
    pass  # The compiler lowers this stub to one prand draw from the current OpenMP thread's stream.

def normal_fill(x: array[float, :]):
    n: int = size(x)  # Number of requested samples.
    i: int = 0  # Output index.
    pair: array[float, :]  # Two uniform draws for Box-Muller.
    u1: float = 0.0  # First uniform variate.
    u2: float = 0.0  # Second uniform variate.
    radius: float = 0.0  # Box-Muller radius.
    angle: float = 0.0  # Box-Muller angle.

    allocate(pair, 2)

    while i < n:
        random_fill(pair)  # Draw a pair of uniforms.
        u1 = pair[0]
        u2 = pair[1]
        if u1 <= 1.0e-12:
            u1 = 1.0e-12  # Avoid log(0).

        radius = sqrt(-2.0 * log(u1))
        angle = 6.283185307179586 * u2
        x[i] = radius * cos(angle)  # First normal sample.
        i += 1
        if i < n:
            x[i] = radius * sin(angle)  # Second normal sample.
            i += 1

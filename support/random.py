# FortScript random support library.
# Serial fill routines lower to generated Fortran helpers.

def random_fill(x: array[float, :]):
    pass  # The compiler lowers this stub to random_number.

def uniform_fill(low: float, high: float, x: array[float, :]):
    pass  # The compiler lowers this stub to random_number plus scaling.

def seed(s: int):
    pass  # The compiler lowers this stub to random_seed setup.

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

# Begin Park-Miller RNG

def pm_step(state: int) -> int:
    i4_huge: int = 2147483647  # Park-Miller modulus.
    q: int = 0  # Quotient for the recurrence.
    next_state: int = 0  # Advanced RNG state.

    q = state / 127773
    next_state = 16807 * (state - q * 127773) - q * 2836
    next_state = next_state % i4_huge
    if next_state <= 0:
        next_state += i4_huge  # Repair non-positive states.
    return next_state

def par_uniform(base_seed: int, i: int) -> float:
    i4_huge: int = 2147483647  # Park-Miller modulus.
    state: int = 0  # Mixed state for this index.

    state = base_seed + 104729 * (i + 1)
    state = state % i4_huge
    if state <= 0:
        state += i4_huge - 1  # Repair zero before stepping.
    state = pm_step(state)
    state = pm_step(state)
    return state * 4.656612875E-10

def par_uniform_2d(base_seed: int, i: int, j: int) -> float:
    i4_huge: int = 2147483647  # Park-Miller modulus.
    state: int = 0  # Mixed state for this index pair.

    state = base_seed + 104729 * (i + 1)
    state += 13007 * (j + 1)
    state = state % i4_huge
    if state <= 0:
        state += i4_huge - 1  # Repair zero before stepping.
    state = pm_step(state)
    state = pm_step(state)
    return state * 4.656612875E-10

def par_uniform_3d(base_seed: int, i: int, j: int, k: int) -> float:
    i4_huge: int = 2147483647  # Park-Miller modulus.
    state: int = 0  # Mixed state for this 3D index.

    state = base_seed + 104729 * (i + 1)
    state += 13007 * (j + 1)
    state += 7919 * (k + 1)
    state = state % i4_huge
    if state <= 0:
        state += i4_huge - 1  # Repair zero before stepping.
    state = pm_step(state)
    state = pm_step(state)
    return state * 4.656612875E-10

def image_seed(base_seed: int) -> int:
    i4_huge: int = 2147483647  # Park-Miller modulus.
    state: int = 0  # Per-image seed.

    state = base_seed + 104729 * (this_image() + 1)
    state = state % i4_huge
    if state <= 0:
        state += i4_huge - 1  # Keep the seed valid.
    return pm_step(state)

# End Park-Miller RNG
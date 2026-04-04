"""More idiomatic NumPy baseline for the molecular dynamics benchmark."""

import numpy as np


def compute_kinetic_energy(vel: np.ndarray, mass: float) -> float:
    """Compute the kinetic energy from the full velocity field."""
    speed_sq = np.square(vel)  # Square each component in one array pass.
    return 0.5 * mass * float(np.sum(speed_sq))  # Collapse to a scalar energy.


def compute(mass: float, pos: np.ndarray, vel: np.ndarray, force: np.ndarray) -> float:
    """Compute the potential energy and pair forces with broadcasting."""
    del mass  # Preserve the original call signature for benchmark parity.
    del vel  # Velocity is unused in the force calculation.

    rij = pos[:, :, None] - pos[:, None, :]  # Pairwise displacement vectors.
    dist_sq = np.sum(rij * rij, axis=0)  # Squared pair distances.
    dist = np.sqrt(dist_sq)  # Euclidean pair distances.

    cutoff = np.pi / 2.0  # Match the original truncated interaction radius.
    clipped = np.minimum(dist, cutoff)  # Apply the cutoff before the trig terms.
    pair_energy = 0.5 * np.sin(clipped) ** 2  # Half contribution per ordered pair.

    np.fill_diagonal(pair_energy, 0.0)  # Remove self-interactions from the energy.
    potential = float(np.sum(pair_energy))  # Reduce all pair contributions.

    scale = np.zeros_like(dist)  # Hold sin(2 r) / r away from the diagonal.
    mask = dist > 0.0  # Exclude self-interactions and exact overlaps.
    scale[mask] = np.sin(2.0 * clipped[mask]) / dist[mask]  # Pair force magnitude.

    force[:, :] = -np.sum(rij * scale[None, :, :], axis=2)  # Accumulate all pair forces.
    return potential


def update(dt: float, mass: float, force: np.ndarray, pos: np.ndarray,
           vel: np.ndarray, acc: np.ndarray) -> None:
    """Advance the position, velocity, and acceleration fields in place."""
    rmass = 1.0 / mass  # Cache the reciprocal mass once per step.
    pos += vel * dt + 0.5 * acc * dt * dt  # Drift positions with the current state.
    vel += 0.5 * dt * (force * rmass + acc)  # Kick velocities with old and new force data.
    acc[:, :] = force * rmass  # Refresh the acceleration buffer.


def initialize(pos: np.ndarray) -> None:
    """Initialize positions with the original Park-Miller sequence."""
    i4_huge = 2147483647  # Match the historical modulus exactly.
    seed = 123456789  # Preserve the original fixed seed.

    for j in range(pos.shape[1]):
        for i in range(pos.shape[0]):
            k = seed // 127773  # Park-Miller quotient step.
            seed = 16807 * (seed - k * 127773) - k * 2836  # Next pseudorandom state.
            seed = seed % i4_huge  # Keep the state in range.
            if seed <= 0:
                seed += i4_huge  # Repair the non-positive corner case.
            pos[i, j] = 10.0 * seed * 4.656612875e-10  # Map into [0, 10].


def md(d_num: int, p_num: int, step_num: int, dt: float):
    """Run the vectorized molecular dynamics benchmark."""
    mass = 1.0  # Keep the original unit-mass setup.

    pos = np.zeros((d_num, p_num))  # Particle positions.
    vel = np.zeros((d_num, p_num))  # Particle velocities.
    acc = np.zeros((d_num, p_num))  # Particle accelerations.
    force = np.zeros((d_num, p_num))  # Pairwise force accumulator.

    initialize(pos)
    potential = compute(mass, pos, vel, force)

    for _ in range(step_num):
        update(dt, mass, force, pos, vel, acc)  # Advance the state one time step.
        potential = compute(mass, pos, vel, force)  # Rebuild the force field.

    kinetic = compute_kinetic_energy(vel, mass)
    return potential, kinetic


if __name__ == "__main__":
    potential, kinetic = md(3, 1000, 200, 0.1)  # Match the existing benchmark inputs.
    print("Potential energy:", potential)
    print("Kinetic energy:", kinetic)

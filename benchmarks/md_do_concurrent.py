# do concurrent FortScript port of benchmarks/md_mod.py.
# The outer particle loops are marked with @par.

import support.random

def compute_kinetic_energy(d_num: int, p_num: int, vel: array[float, :, :], mass: float) -> float:
    kinetic: float = 0.0  # Sum the squared speeds.
    for k in range(d_num):
        for j in range(p_num):
            kinetic += vel[k, j] * vel[k, j]
    return 0.5 * mass * kinetic

def compute_forces_parallel(p_num: int, pos: array[float, :, :], force: array[float, :, :]) -> float:
    cutoff: float = 1.5707963267948966  # pi / 2
    potential: float = 0.0  # Reduced potential energy
    dx: float = 0.0  # Private x displacement
    dy: float = 0.0  # Private y displacement
    dz: float = 0.0  # Private z displacement
    dist2: float = 0.0  # Private squared distance
    dist: float = 0.0  # Private distance
    trunc: float = 0.0  # Private truncated distance
    scale: float = 0.0  # Private force scale

    @par
    @local(dx)
    @local(dy)
    @local(dz)
    @local(dist2)
    @local(dist)
    @local(trunc)
    @local(scale)
    @reduce(add: potential)
    for i in range(p_num):
        force[0, i] = 0.0  # Each iteration owns column i.
        force[1, i] = 0.0  # Each iteration owns column i.
        force[2, i] = 0.0  # Each iteration owns column i.
        for j in range(p_num):
            if not (i == j):
                dx = pos[0, i] - pos[0, j]  # Relative x
                dy = pos[1, i] - pos[1, j]  # Relative y
                dz = pos[2, i] - pos[2, j]  # Relative z
                dist2 = dx * dx + dy * dy + dz * dz  # Radius squared
                dist = sqrt(dist2)  # Radius
                trunc = dist  # Default to the full radius.
                if trunc > cutoff:
                    trunc = cutoff  # Match the original truncation.
                potential += 0.5 * sin(trunc) * sin(trunc)  # Reduced scalar contribution.
                scale = sin(2.0 * trunc) / dist  # Pair force magnitude
                force[0, i] -= dx * scale  # Write only the owned force column.
                force[1, i] -= dy * scale  # Write only the owned force column.
                force[2, i] -= dz * scale  # Write only the owned force column.
    return potential

def update_state_parallel(d_num: int, p_num: int, dt: float, mass: float,
                          force: array[float, :, :], pos: array[float, :, :],
                          vel: array[float, :, :], acc: array[float, :, :]):
    rmass: float = 1.0 / mass  # Cache the reciprocal mass.

    @par
    for j in range(p_num):
        for k in range(d_num):
            pos[k, j] = pos[k, j] + vel[k, j] * dt + 0.5 * acc[k, j] * dt * dt  # Position step
            vel[k, j] = vel[k, j] + 0.5 * dt * (force[k, j] * rmass + acc[k, j])  # Velocity step
            acc[k, j] = force[k, j] * rmass  # Refresh the acceleration.

def initialize_positions(d_num: int, p_num: int, pos: array[float, :, :]):
    rng_seed: int = 123456789  # Fixed initialization seed.
    box_low: float = 0.0  # Lower coordinate bound.
    box_high: float = 10.0  # Upper coordinate bound.
    pos_flat: array[float, :]  # Flat buffer for serial random fill.
    flat_index: int = 0  # Linear index into the flat buffer.

    allocate(pos_flat, d_num * p_num)
    seed(rng_seed)  # Set the reproducible stream.
    uniform_fill(box_low, box_high, pos_flat)  # Draw positions in the simulation box.

    for j in range(p_num):
        for k in range(d_num):
            pos[k, j] = pos_flat[flat_index]  # Copy to the 2D position array.
            flat_index += 1  # Advance the flat buffer index.

def md(d_num: int, p_num: int, step_num: int, dt: float):
    if not (d_num == 3):
        print("md_mod_do_concurrent expects d_num == 3")  # Keep the benchmark shape fixed.
        return

    mass: float = 1.0  # Unit particle mass
    potential: float = 0.0  # Final potential energy
    kinetic: float = 0.0  # Final kinetic energy

    pos: array[float, :, :]  # Particle positions
    vel: array[float, :, :]  # Particle velocities
    acc: array[float, :, :]  # Particle accelerations
    force: array[float, :, :]  # Particle forces

    allocate(pos, d_num, p_num)
    allocate(vel, d_num, p_num)
    allocate(acc, d_num, p_num)
    allocate(force, d_num, p_num)

    for j in range(p_num):
        for k in range(d_num):
            vel[k, j] = 0.0  # Start at rest.
            acc[k, j] = 0.0  # Start with zero acceleration.
            force[k, j] = 0.0  # Clear the force buffer.

    initialize_positions(d_num, p_num, pos)
    potential = compute_forces_parallel(p_num, pos, force)  # Build the first force field.

    for step in range(step_num):
        update_state_parallel(d_num, p_num, dt, mass, force, pos, vel, acc)  # Drift and kick
        potential = compute_forces_parallel(p_num, pos, force)  # Refresh the forces.

    kinetic = compute_kinetic_energy(d_num, p_num, vel, mass)

    print("Potential energy:", potential)  # Match the benchmark summary.
    print("Kinetic energy:", kinetic)  # Match the benchmark summary.

def main():
    md(3, 20000, 10, 0.1) 

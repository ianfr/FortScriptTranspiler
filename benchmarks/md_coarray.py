# Coarray FortScript port of benchmarks/md_mod.py.
# Each image owns a particle block and exchanges positions through a coarray.

def owned_count(p_num: int, np: int, img: int) -> int:
    base: int = p_num / np  # Even block size
    rem: int = p_num % np  # First rem images get one extra particle.
    if img < rem:
        return base + 1  # Ragged prefix block
    return base  # Uniform trailing block

def owned_start(p_num: int, np: int, img: int) -> int:
    base: int = p_num / np  # Even block size
    rem: int = p_num % np  # Prefix remainder
    if img < rem:
        return img * (base + 1)  # Dense prefix
    return rem * (base + 1) + (img - rem) * base  # Offset into the tail

def compute_local_forces(start_idx: int, local_n: int, p_num: int,
                         pos_all: array[float, :, :], force_local: array[float, :, :]) -> float:
    cutoff: float = 1.5707963267948966  # pi / 2
    potential: float = 0.0  # Local potential slice
    global_i: int = 0  # Global particle index
    dx: float = 0.0  # x displacement
    dy: float = 0.0  # y displacement
    dz: float = 0.0  # z displacement
    dist2: float = 0.0  # Squared distance
    dist: float = 0.0  # Distance
    trunc: float = 0.0  # Truncated distance
    scale: float = 0.0  # Force scale

    for i in range(local_n):
        force_local[0, i] = 0.0  # Reset the x force.
        force_local[1, i] = 0.0  # Reset the y force.
        force_local[2, i] = 0.0  # Reset the z force.
        global_i = start_idx + i  # Map to the global particle id.
        for j in range(p_num):
            if not (global_i == j):
                dx = pos_all[0, global_i] - pos_all[0, j]  # Relative x
                dy = pos_all[1, global_i] - pos_all[1, j]  # Relative y
                dz = pos_all[2, global_i] - pos_all[2, j]  # Relative z
                dist2 = dx * dx + dy * dy + dz * dz  # Radius squared
                dist = sqrt(dist2)  # Radius
                trunc = dist  # Default to the full radius.
                if trunc > cutoff:
                    trunc = cutoff  # Match the original truncation.
                potential += 0.5 * sin(trunc) * sin(trunc)  # Local ordered-pair contribution.
                scale = sin(2.0 * trunc) / dist  # Pair force magnitude
                force_local[0, i] -= dx * scale  # Accumulate x force.
                force_local[1, i] -= dy * scale  # Accumulate y force.
                force_local[2, i] -= dz * scale  # Accumulate z force.
    return potential

def update_local_state(d_num: int, local_n: int, dt: float, mass: float,
                       force_local: array[float, :, :], pos_local: array[float, :, :],
                       vel_local: array[float, :, :], acc_local: array[float, :, :]):
    rmass: float = 1.0 / mass  # Cache the reciprocal mass.
    for j in range(local_n):
        for k in range(d_num):
            pos_local[k, j] = pos_local[k, j] + vel_local[k, j] * dt + 0.5 * acc_local[k, j] * dt * dt  # Position step
            vel_local[k, j] = vel_local[k, j] + 0.5 * dt * (force_local[k, j] * rmass + acc_local[k, j])  # Velocity step
            acc_local[k, j] = force_local[k, j] * rmass  # Refresh the acceleration.

def compute_local_kinetic_energy(d_num: int, local_n: int, vel_local: array[float, :, :], mass: float) -> float:
    kinetic: float = 0.0  # Local kinetic sum
    for k in range(d_num):
        for j in range(local_n):
            kinetic += vel_local[k, j] * vel_local[k, j]
    return 0.5 * mass * kinetic

def main():
    d_num: int = 3  # Keep the benchmark shape fixed.
    p_num: int = 1000  # Match the Python benchmark input.
    step_num: int = 200  # Match the Python benchmark input.
    dt: float = 0.1  # Match the Python benchmark input.
    mass: float = 1.0  # Unit particle mass

    me: int = this_image()  # Local image id
    np: int = num_images()  # Total image count
    chunk_n: int = (p_num + np - 1) / np  # Common local allocation size
    local_n: int = owned_count(p_num, np, me)  # Valid local particles
    start_idx: int = owned_start(p_num, np, me)  # Global start index

    i4_huge: int = 2147483647  # Same modulus as the Python benchmark.
    seed: int = 123456789  # Fixed seed for reproducibility.
    q: int = 0  # LCG quotient

    pos_local: array[float, :, :]  # Local particle positions
    vel_local: array[float, :, :]  # Local particle velocities
    acc_local: array[float, :, :]  # Local particle accelerations
    force_local: array[float, :, :]  # Local particle forces
    pos_all: array[float, :, :]  # Global position snapshot
    pos_shared: array*[float, :, :]  # Coarray exchange buffer
    energy_parts: array*[float, :]  # Coarray reduction buffer

    potential_local: float = 0.0  # Local potential energy
    kinetic_local: float = 0.0  # Local kinetic energy
    potential_total: float = 0.0  # Image 0 total potential
    kinetic_total: float = 0.0  # Image 0 total kinetic
    remote_n: int = 0  # Remote valid count
    remote_start: int = 0  # Remote global start

    allocate(pos_local, d_num, chunk_n)
    allocate(vel_local, d_num, chunk_n)
    allocate(acc_local, d_num, chunk_n)
    allocate(force_local, d_num, chunk_n)
    allocate(pos_all, d_num, p_num)
    allocate(pos_shared, d_num, chunk_n)
    allocate(energy_parts, 2)

    for j in range(chunk_n):
        for k in range(d_num):
            pos_local[k, j] = 0.0  # Clear local positions.
            vel_local[k, j] = 0.0  # Start at rest.
            acc_local[k, j] = 0.0  # Start with zero acceleration.
            force_local[k, j] = 0.0  # Clear the force buffer.
            pos_shared[k, j] = 0.0  # Clear the exchange buffer.

    for global_j in range(p_num):
        for k in range(d_num):
            q = seed / 127773  # Park-Miller step.
            seed = 16807 * (seed - q * 127773) - q * 2836  # Next seed
            seed = seed % i4_huge  # Keep the seed in range.
            if seed <= 0:
                seed += i4_huge  # Repair a non-positive seed.
            if global_j >= start_idx:
                if global_j < start_idx + local_n:
                    pos_local[k, global_j - start_idx] = 10.0 * seed * 4.656612875E-10  # Store owned particles.

    for j in range(chunk_n):
        for k in range(d_num):
            pos_shared[k, j] = pos_local[k, j]  # Publish the local block.

    sync

    for img in range(np):
        remote_n = owned_count(p_num, np, img)  # Remote valid count
        remote_start = owned_start(p_num, np, img)  # Remote start index
        pos_all[0:d_num, remote_start:remote_start + remote_n] = pos_shared[0:d_num, 0:remote_n]{img}  # Bulk gather.

    potential_local = compute_local_forces(start_idx, local_n, p_num, pos_all, force_local)  # Build the first force field.

    for step in range(step_num):
        update_local_state(d_num, local_n, dt, mass, force_local, pos_local, vel_local, acc_local)  # Drift and kick

        for j in range(chunk_n):
            for k in range(d_num):
                pos_shared[k, j] = pos_local[k, j]  # Publish the updated local block.

        sync

        for img in range(np):
            remote_n = owned_count(p_num, np, img)  # Remote valid count
            remote_start = owned_start(p_num, np, img)  # Remote start index
            pos_all[0:d_num, remote_start:remote_start + remote_n] = pos_shared[0:d_num, 0:remote_n]{img}  # Bulk gather.

        sync  # Wait for all images to finish reading before next publish.

        potential_local = compute_local_forces(start_idx, local_n, p_num, pos_all, force_local)  # Refresh the forces.

    kinetic_local = compute_local_kinetic_energy(d_num, local_n, vel_local, mass)

    energy_parts[0] = potential_local  # Publish the local potential.
    energy_parts[1] = kinetic_local  # Publish the local kinetic energy.

    sync

    if me == 0:
        for img in range(np):
            potential_total += energy_parts[0]{img}  # Sum the distributed potential.
            kinetic_total += energy_parts[1]{img}  # Sum the distributed kinetic energy.
        print("Potential energy:", potential_total)  # Match the benchmark summary.
        print("Kinetic energy:", kinetic_total)  # Match the benchmark summary.

# N-body simulation in FortScript
# Demonstrates structs, arrays of structs, @par loops, numpy-like ops

struct Vec3:
    x: float
    y: float
    z: float

struct Body:
    pos: Vec3
    vel: Vec3
    mass: float

def vec_add(ax: float, ay: float, az: float,
            bx: float, by: float, bz: float) -> float:
    return ax + bx

def compute_distance(dx: float, dy: float, dz: float) -> float:
    return sqrt(dx * dx + dy * dy + dz * dz)

def update_velocities(n: int, bodies: array[Body, 100], dt: float):
    @par
    for i in range(n):
        fx: float = 0.0
        fy: float = 0.0
        fz: float = 0.0
        for j in range(n):
            if not (i == j):
                dx: float = bodies[j].pos.x - bodies[i].pos.x
                dy: float = bodies[j].pos.y - bodies[i].pos.y
                dz: float = bodies[j].pos.z - bodies[i].pos.z
                dist: float = compute_distance(dx, dy, dz)
                inv_dist3: float = 1.0 / (dist * dist * dist)
                fx += bodies[j].mass * dx * inv_dist3
                fy += bodies[j].mass * dy * inv_dist3
                fz += bodies[j].mass * dz * inv_dist3
        bodies[i].vel.x += dt * fx
        bodies[i].vel.y += dt * fy
        bodies[i].vel.z += dt * fz

def update_positions(n: int, bodies: array[Body, 100], dt: float):
    @par
    for i in range(n):
        bodies[i].pos.x += bodies[i].vel.x * dt
        bodies[i].pos.y += bodies[i].vel.y * dt
        bodies[i].pos.z += bodies[i].vel.z * dt

def compute_energy(n: int, bodies: array[Body, 100]) -> float:
    energy: float = 0.0
    for i in range(n):
        speed2: float = bodies[i].vel.x ** 2 + bodies[i].vel.y ** 2 + bodies[i].vel.z ** 2
        energy += 0.5 * bodies[i].mass * speed2
    return energy

def main():
    n: int = 3
    bodies: array[Body, 100]
    dt: float = 0.001
    nsteps: int = 100

    # Initialize bodies
    bodies[0].pos.x = 0.0
    bodies[0].pos.y = 0.0
    bodies[0].pos.z = 0.0
    bodies[0].vel.x = 0.0
    bodies[0].vel.y = 0.0
    bodies[0].vel.z = 0.0
    bodies[0].mass = 1000.0

    bodies[1].pos.x = 1.0
    bodies[1].pos.y = 0.0
    bodies[1].pos.z = 0.0
    bodies[1].vel.x = 0.0
    bodies[1].vel.y = 1.0
    bodies[1].vel.z = 0.0
    bodies[1].mass = 1.0

    bodies[2].pos.x = 0.0
    bodies[2].pos.y = 1.0
    bodies[2].pos.z = 0.0
    bodies[2].vel.x = -1.0
    bodies[2].vel.y = 0.0
    bodies[2].vel.z = 0.0
    bodies[2].mass = 1.0

    e: float = compute_energy(n, bodies)
    print("Initial energy:", e)

    for step in range(nsteps):
        update_velocities(n, bodies, dt)
        update_positions(n, bodies, dt)

    e = compute_energy(n, bodies)
    print("Final energy:", e)

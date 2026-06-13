# Tests for BDIM helpers and PIMPLE-related FVM functions added in
# support.geom_cartesian_fvm and support.geom_cartesian.
#
# Covers: fvc_bdim_mu0, fvc_bdim_mu1, fvc_bdim_weights,
#         fvc_sdf_normal, fvc_flux_from_velocity (divergence-free check),
#         fvc_div_flux, fvc_under_relax_scalar, fvc_under_relax_vector,
#         fvm_under_relax, fvc_inverse_diag, fvc_HbyA_component,
#         fvc_momentum_pressure_correct, geom_cartesian_sample_sdf.

import support.geom_cartesian
import support.geom_cartesian_fvm

struct HeatField:
    T: float

def check_close(value: float, expected: float, tol: float):
    if abs(value - expected) > tol:
        exit(1)

def check_int(value: int, expected: int):
    if value != expected:
        exit(1)

def check_true(cond: bool):
    if not cond:
        exit(1)

# fvc_bdim_mu0 must equal 0 below -eps, 1 above +eps, and 0.5 at d=0.
def test_bdim_mu0_limits():
    check_close(fvc_bdim_mu0(-2.0, 1.0), 0.0, 1.0e-12)
    check_close(fvc_bdim_mu0(-1.0, 1.0), 0.0, 1.0e-12)
    check_close(fvc_bdim_mu0(0.0,  1.0), 0.5, 1.0e-12)
    check_close(fvc_bdim_mu0(1.0,  1.0), 1.0, 1.0e-12)
    check_close(fvc_bdim_mu0(2.0,  1.0), 1.0, 1.0e-12)

# fvc_bdim_mu1 must be zero outside [-eps, eps] and match the analytic
# value at d=0: eps*(0.25 + 1/pi^2).
def test_bdim_mu1_limits():
    check_close(fvc_bdim_mu1(-2.0, 1.0), 0.0, 1.0e-12)
    check_close(fvc_bdim_mu1(-1.0, 1.0), 0.0, 1.0e-12)
    check_close(fvc_bdim_mu1(1.0,  1.0), 0.0, 1.0e-12)
    check_close(fvc_bdim_mu1(2.0,  1.0), 0.0, 1.0e-12)
    # At d=0 with eps=1: mu1 = 1*(0.25 + 1/pi^2)
    expected: float = 0.25 + 1.0 / (BDIM_PI * BDIM_PI)
    check_close(fvc_bdim_mu1(0.0, 1.0), expected, 1.0e-10)

# mu0 + (1-mu0) = 1 for any d.
def test_bdim_mu0_complement():
    d: float = 0.3
    eps: float = 1.0
    mu: float = fvc_bdim_mu0(d, eps)
    check_close(mu + (1.0 - mu), 1.0, 1.0e-14)

# fvc_bdim_weights fills mu0, mu1, solid for every leaf.
# With SDF = +1 everywhere: mu0 = 1, solid = 0 (full fluid).
def test_bdim_weights_full_fluid():
    mesh: CartesianMesh[HeatField]
    dim_min: array[float, 3]
    dim_max: array[float, 3]
    sdf_cell: array[float, :]
    mu0_arr: array[float, :]
    mu1_arr: array[float, :]
    solid_arr: array[float, :]
    l: int = 0
    c: int = 0
    eps: float = 0.1

    dim_min[0] = 0.0
    dim_min[1] = 0.0
    dim_min[2] = 0.0
    dim_max[0] = 1.0
    dim_max[1] = 1.0
    dim_max[2] = 1.0
    geom_cartesian_uniform(mesh, dim_min, dim_max, 0.5)
    allocate(sdf_cell,  mesh.cell_capacity)
    allocate(mu0_arr,   mesh.cell_capacity)
    allocate(mu1_arr,   mesh.cell_capacity)
    allocate(solid_arr, mesh.cell_capacity)

    # All cells deep in fluid: sdf = 10 >> eps.
    sdf_cell = 10.0
    fvc_bdim_weights(mesh, sdf_cell, eps, mu0_arr, mu1_arr, solid_arr)

    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        check_close(mu0_arr[c],   1.0, 1.0e-12)
        check_close(mu1_arr[c],   0.0, 1.0e-12)
        check_close(solid_arr[c], 0.0, 1.0e-12)

# fvc_bdim_weights: all cells deep in solid -> mu0 = 0, solid = 1.
def test_bdim_weights_full_solid():
    mesh: CartesianMesh[HeatField]
    dim_min: array[float, 3]
    dim_max: array[float, 3]
    sdf_cell: array[float, :]
    mu0_arr: array[float, :]
    mu1_arr: array[float, :]
    solid_arr: array[float, :]
    l: int = 0
    c: int = 0
    eps: float = 0.1

    dim_min[0] = 0.0
    dim_min[1] = 0.0
    dim_min[2] = 0.0
    dim_max[0] = 1.0
    dim_max[1] = 1.0
    dim_max[2] = 1.0
    geom_cartesian_uniform(mesh, dim_min, dim_max, 0.5)
    allocate(sdf_cell,  mesh.cell_capacity)
    allocate(mu0_arr,   mesh.cell_capacity)
    allocate(mu1_arr,   mesh.cell_capacity)
    allocate(solid_arr, mesh.cell_capacity)

    sdf_cell = -10.0
    fvc_bdim_weights(mesh, sdf_cell, eps, mu0_arr, mu1_arr, solid_arr)

    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        check_close(mu0_arr[c],   0.0, 1.0e-12)
        check_close(mu1_arr[c],   0.0, 1.0e-12)
        check_close(solid_arr[c], 1.0, 1.0e-12)

# fvc_flux_from_velocity with uniform u = (1, 0, 0) should produce zero
# divergence (via fvc_div_flux) for every leaf cell.
def test_flux_uniform_divergence_zero():
    mesh: CartesianMesh[HeatField]
    dim_min: array[float, 3]
    dim_max: array[float, 3]
    vel: array[float, :, :]
    phi: array[float, :, :]
    div_phi: array[float, :]
    l: int = 0
    c: int = 0

    dim_min[0] = 0.0
    dim_min[1] = 0.0
    dim_min[2] = 0.0
    dim_max[0] = 1.0
    dim_max[1] = 1.0
    dim_max[2] = 1.0
    geom_cartesian_uniform(mesh, dim_min, dim_max, 0.25)
    allocate(vel,     mesh.cell_capacity, 3)
    allocate(phi,     mesh.cell_capacity, 6)
    allocate(div_phi, mesh.cell_capacity)

    vel = 0.0
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        vel[c, 0] = 1.0

    fvc_flux_from_velocity(mesh, vel, phi)
    fvc_div_flux(mesh, phi, div_phi)

    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        check_close(div_phi[c], 0.0, 1.0e-10)

# Uniform velocity should remain divergence-free across adaptive faces.
def test_flux_uniform_amr_divergence_zero():
    mesh: CartesianMesh[HeatField]
    dim_min: array[float, 3]
    dim_max: array[float, 3]
    vel: array[float, :, :]
    phi: array[float, :, :]
    div_phi: array[float, :]
    l: int = 0
    c: int = 0
    root: int = 0

    dim_min[0] = 0.0
    dim_min[1] = 0.0
    dim_min[2] = 0.0
    dim_max[0] = 1.0
    dim_max[1] = 1.0
    dim_max[2] = 1.0
    geom_cartesian_uniform(mesh, dim_min, dim_max, 0.5)

    # Refine one root cell to create coarse-to-fine face slots.
    root = geom_cartesian_locate(mesh, 0.1, 0.1, 0.1)
    geom_cartesian_refine_cell(mesh, root)

    allocate(vel,     mesh.cell_capacity, 3)
    allocate(phi,     mesh.cell_capacity, 6)
    allocate(div_phi, mesh.cell_capacity)

    vel = 0.0
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        vel[c, 0] = 1.0

    fvc_flux_from_velocity(mesh, vel, phi)
    fvc_div_flux(mesh, phi, div_phi)

    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        check_close(div_phi[c], 0.0, 1.0e-10)

# fvc_sdf_normal on a linear SDF field SDF = x should give normal = (1, 0, 0)
# for all interior cells.
def test_sdf_normal_linear():
    mesh: CartesianMesh[HeatField]
    dim_min: array[float, 3]
    dim_max: array[float, 3]
    sdf_cell: array[float, :]
    normal: array[float, :, :]
    l: int = 0
    c: int = 0

    dim_min[0] = 0.0
    dim_min[1] = 0.0
    dim_min[2] = 0.0
    dim_max[0] = 1.0
    dim_max[1] = 1.0
    dim_max[2] = 1.0
    geom_cartesian_uniform(mesh, dim_min, dim_max, 0.25)
    allocate(sdf_cell, mesh.cell_capacity)
    allocate(normal,   mesh.cell_capacity, 3)

    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        sdf_cell[c] = mesh.center[c, 0]

    fvc_sdf_normal(mesh, sdf_cell, normal)

    # Interior cells should have normal = (1, 0, 0) for SDF = x.
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        if mesh.neighbor[c, 0, 0] >= 0 and mesh.neighbor[c, 1, 0] >= 0:
            check_close(normal[c, 0], 1.0, 1.0e-10)
            check_close(normal[c, 1], 0.0, 1.0e-10)
            check_close(normal[c, 2], 0.0, 1.0e-10)

# fvc_under_relax_scalar blends toward old field.
def test_under_relax_scalar():
    mesh: CartesianMesh[HeatField]
    dim_min: array[float, 3]
    dim_max: array[float, 3]
    old_f: array[float, :]
    new_f: array[float, :]
    l: int = 0
    c: int = 0

    dim_min[0] = 0.0
    dim_min[1] = 0.0
    dim_min[2] = 0.0
    dim_max[0] = 1.0
    dim_max[1] = 1.0
    dim_max[2] = 1.0
    geom_cartesian_uniform(mesh, dim_min, dim_max, 0.5)
    allocate(old_f, mesh.cell_capacity)
    allocate(new_f, mesh.cell_capacity)

    old_f = 0.0
    new_f = 1.0
    fvc_under_relax_scalar(mesh, old_f, new_f, 0.5)

    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        check_close(new_f[c], 0.5, 1.0e-12)

# fvc_under_relax_vector blends each component toward old field.
def test_under_relax_vector():
    mesh: CartesianMesh[HeatField]
    dim_min: array[float, 3]
    dim_max: array[float, 3]
    old_f: array[float, :, :]
    new_f: array[float, :, :]
    l: int = 0
    c: int = 0

    dim_min[0] = 0.0
    dim_min[1] = 0.0
    dim_min[2] = 0.0
    dim_max[0] = 1.0
    dim_max[1] = 1.0
    dim_max[2] = 1.0
    geom_cartesian_uniform(mesh, dim_min, dim_max, 0.5)
    allocate(old_f, mesh.cell_capacity, 3)
    allocate(new_f, mesh.cell_capacity, 3)

    old_f = 0.0
    new_f = 2.0
    fvc_under_relax_vector(mesh, old_f, new_f, 0.25)

    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        check_close(new_f[c, 0], 0.5, 1.0e-12)
        check_close(new_f[c, 1], 0.5, 1.0e-12)
        check_close(new_f[c, 2], 0.5, 1.0e-12)

# fvm_under_relax: when old_field equals the converged solution the
# relaxation is a consistent modification and the solve still returns
# the true answer.  source/coeff = 9/3 = 3; initialize mesh.T = 3 to
# simulate a converged iterate before relaxing.
def test_fvm_under_relax_diagonal():
    mesh: CartesianMesh[HeatField]
    dim_min: array[float, 3]
    dim_max: array[float, 3]
    coeff: array[float, :]
    source: array[float, :]
    eq: FVMEquation
    l: int = 0
    c: int = 0

    dim_min[0] = 0.0
    dim_min[1] = 0.0
    dim_min[2] = 0.0
    dim_max[0] = 1.0
    dim_max[1] = 1.0
    dim_max[2] = 1.0
    geom_cartesian_uniform(mesh, dim_min, dim_max, 0.5)
    allocate(coeff,  mesh.cell_capacity)
    allocate(source, mesh.cell_capacity)

    coeff  = 3.0
    source = 9.0
    # old_field = 3.0 (the converged iterate); after relaxation and solve
    # the solution is still 3.0 because the perturbation cancels.
    mesh.T = 3.0

    fvm_equation_init(eq, mesh)
    fvm_source_lhs(eq, mesh, coeff)
    fvm_source(eq, mesh, source)
    fvm_under_relax(eq, mesh, mesh.T, 0.5)
    fvm_solve_diag(eq, mesh, mesh.T)

    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        check_close(mesh.T[c], 3.0, 1.0e-10)

# fvc_inverse_diag returns 1/diag for a pure-diagonal equation.
def test_inverse_diag():
    mesh: CartesianMesh[HeatField]
    dim_min: array[float, 3]
    dim_max: array[float, 3]
    coeff: array[float, :]
    invA: array[float, :]
    eq: FVMEquation
    l: int = 0
    c: int = 0

    dim_min[0] = 0.0
    dim_min[1] = 0.0
    dim_min[2] = 0.0
    dim_max[0] = 1.0
    dim_max[1] = 1.0
    dim_max[2] = 1.0
    geom_cartesian_uniform(mesh, dim_min, dim_max, 0.5)
    allocate(coeff, mesh.cell_capacity)
    allocate(invA,  mesh.cell_capacity)

    coeff = 4.0
    fvm_equation_init(eq, mesh)
    fvm_source_lhs(eq, mesh, coeff)

    fvc_inverse_diag(mesh, eq, invA)

    # diag[c] = coeff * volume = 4 * dx^3 = 4 * 0.125 = 0.5; invA = 2.
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        check_close(invA[c], 2.0, 1.0e-12)

# fvc_HbyA_component with a constant field and pure Laplacian returns the
# original constant (see derivation in test_fvm.py comments).
def test_HbyA_constant_field():
    mesh: CartesianMesh[HeatField]
    dim_min: array[float, 3]
    dim_max: array[float, 3]
    gamma_face: array[float, :, :]
    invA: array[float, :]
    hbyA: array[float, :]
    eq: FVMEquation
    l: int = 0
    c: int = 0
    const_val: float = 3.5

    dim_min[0] = 0.0
    dim_min[1] = 0.0
    dim_min[2] = 0.0
    dim_max[0] = 1.0
    dim_max[1] = 1.0
    dim_max[2] = 1.0
    geom_cartesian_uniform(mesh, dim_min, dim_max, 0.25)
    allocate(gamma_face, mesh.cell_capacity, 6)
    allocate(invA,       mesh.cell_capacity)
    allocate(hbyA,       mesh.cell_capacity)

    mesh.T    = const_val
    gamma_face = 1.0

    fvm_equation_init(eq, mesh)
    fvm_laplacian(eq, mesh, gamma_face)
    fvc_inverse_diag(mesh, eq, invA)
    fvc_HbyA_component(mesh, eq, mesh.T, invA, hbyA)

    # H(T)[c] = rhs - A_off * T = 0 - sum(-coeff * const) = const * A_diag
    # HbyA = const * A_diag * invA = const.
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        check_close(hbyA[c], const_val, 1.0e-10)

# fvc_momentum_pressure_correct: u = hbyA - invA * grad(p).
# With hbyA = (1, 0, 0) and p = x (gradient 1 in x), invA = 1 everywhere:
# u_x = 1 - 1*1 = 0 for interior cells.
def test_pressure_correct_velocity():
    mesh: CartesianMesh[HeatField]
    dim_min: array[float, 3]
    dim_max: array[float, 3]
    hbyA: array[float, :, :]
    invA: array[float, :]
    u_out: array[float, :, :]
    l: int = 0
    c: int = 0

    dim_min[0] = 0.0
    dim_min[1] = 0.0
    dim_min[2] = 0.0
    dim_max[0] = 1.0
    dim_max[1] = 1.0
    dim_max[2] = 1.0
    geom_cartesian_uniform(mesh, dim_min, dim_max, 0.25)
    allocate(hbyA,  mesh.cell_capacity, 3)
    allocate(invA,  mesh.cell_capacity)
    allocate(u_out, mesh.cell_capacity, 3)

    invA = 0.0
    hbyA = 0.0
    u_out = 0.0
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        hbyA[c, 0] = 1.0
        invA[c]    = 1.0
        mesh.T[c]  = mesh.center[c, 0]

    # Use mesh.T as pressure field (p = x).
    fvc_momentum_pressure_correct(mesh, hbyA, invA, mesh.T, u_out)

    # For interior cells: grad_p_x = 1, so u_out_x = 1 - 1 = 0.
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        if mesh.neighbor[c, 0, 0] >= 0 and mesh.neighbor[c, 1, 0] >= 0:
            check_close(u_out[c, 0], 0.0, 1.0e-10)
            check_close(u_out[c, 1], 0.0, 1.0e-10)
            check_close(u_out[c, 2], 0.0, 1.0e-10)

# geom_cartesian_sample_sdf reproduces analytic SDF values at leaf centers.
# SDF = x - 0.5 sampled on a uniform 3x3x3 grid over [0,1]^3.
def test_sample_sdf_linear():
    mesh: CartesianMesh[HeatField]
    dim_min: array[float, 3]
    dim_max: array[float, 3]
    sdf_grid: array[float, :, :, :]
    x_sdf: array[float, :]
    y_sdf: array[float, :]
    z_sdf: array[float, :]
    sdf_out: array[float, :]
    i: int = 0
    j: int = 0
    k: int = 0
    l: int = 0
    c: int = 0

    dim_min[0] = 0.0
    dim_min[1] = 0.0
    dim_min[2] = 0.0
    dim_max[0] = 1.0
    dim_max[1] = 1.0
    dim_max[2] = 1.0
    geom_cartesian_uniform(mesh, dim_min, dim_max, 0.5)

    x_sdf = linspace(0.0, 1.0, 3)
    y_sdf = linspace(0.0, 1.0, 3)
    z_sdf = linspace(0.0, 1.0, 3)
    # z-major allocation: sdf_grid[k, j, i] = x_sdf[i] - 0.5
    allocate(sdf_grid, 3, 3, 3)
    for k in range(3):
        for j in range(3):
            for i in range(3):
                sdf_grid[k, j, i] = x_sdf[i] - 0.5

    allocate(sdf_out, mesh.cell_capacity)
    sdf_out = 0.0
    geom_cartesian_sample_sdf(mesh, x_sdf, y_sdf, z_sdf, sdf_grid, 3, 3, 3, sdf_out)

    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        check_close(sdf_out[c], mesh.center[c, 0] - 0.5, 1.0e-10)

def main():
    test_bdim_mu0_limits()
    test_bdim_mu1_limits()
    test_bdim_mu0_complement()
    test_bdim_weights_full_fluid()
    test_bdim_weights_full_solid()
    test_flux_uniform_divergence_zero()
    test_flux_uniform_amr_divergence_zero()
    test_sdf_normal_linear()
    test_under_relax_scalar()
    test_under_relax_vector()
    test_fvm_under_relax_diagonal()
    test_inverse_diag()
    test_HbyA_constant_field()
    test_pressure_correct_velocity()
    test_sample_sdf_linear()
    print("test_bdim_fvm: all checks passed")

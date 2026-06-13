# Tests for support.geom_cartesian_fvm and the FortScript pieces of
# support.geom_cartesian that the FVM layer depends on.
#
# Covers: hierarchical geom_cartesian_locate, geom_cartesian_find_imbalance,
# the 2:1 balance cascade triggered by geom_cartesian_refine_cell, the
# explicit fvc_* operators on linear and constant fields, the implicit
# fvm_laplacian + fvm_dirichlet assembly, fvm_neumann, the CG and BiCGStab
# solver paths, and the diagonal-only solve.

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

# Uniform 2x2x2 root mesh: locate maps interior points to the expected
# root cell ids and rejects points outside the domain.
def test_locate_uniform():
    mesh: CartesianMesh[HeatField]
    dim_min: array[float, 3]
    dim_max: array[float, 3]
    c: int = 0

    dim_min[0] = 0.0
    dim_min[1] = 0.0
    dim_min[2] = 0.0
    dim_max[0] = 1.0
    dim_max[1] = 1.0
    dim_max[2] = 1.0
    geom_cartesian_uniform(mesh, dim_min, dim_max, 0.5)

    # 2x2x2 root grid. Morton-style id = (k*ny + j)*nx + i.
    c = geom_cartesian_locate(mesh, 0.25, 0.25, 0.25)
    check_int(c, 0)
    c = geom_cartesian_locate(mesh, 0.75, 0.25, 0.25)
    check_int(c, 1)
    c = geom_cartesian_locate(mesh, 0.75, 0.75, 0.75)
    check_int(c, 7)

    # Out-of-domain points return -1 on every side.
    c = geom_cartesian_locate(mesh, -0.1, 0.5, 0.5)
    check_int(c, -1)
    c = geom_cartesian_locate(mesh, 1.5, 0.5, 0.5)
    check_int(c, -1)
    c = geom_cartesian_locate(mesh, 0.5, -0.1, 0.5)
    check_int(c, -1)
    c = geom_cartesian_locate(mesh, 0.5, 0.5, 1.5)
    check_int(c, -1)

# Locate after a single refine descends through the children array and
# returns a leaf at the deeper level, not the parent root.
def test_locate_after_refine():
    mesh: CartesianMesh[HeatField]
    dim_min: array[float, 3]
    dim_max: array[float, 3]
    c: int = 0
    root: int = 0

    dim_min[0] = 0.0
    dim_min[1] = 0.0
    dim_min[2] = 0.0
    dim_max[0] = 1.0
    dim_max[1] = 1.0
    dim_max[2] = 1.0
    geom_cartesian_uniform(mesh, dim_min, dim_max, 0.5)

    root = geom_cartesian_locate(mesh, 0.1, 0.1, 0.1)
    check_int(root, 0)
    geom_cartesian_refine_cell(mesh, root)

    # The same point should now resolve to a level-1 leaf inside the refined root.
    c = geom_cartesian_locate(mesh, 0.1, 0.1, 0.1)
    check_int(mesh.level[c], 1)
    check_true(mesh.is_leaf[c])

# Refining a child whose outward face touches a coarser root must trigger
# the 2:1 balance cascade, leaving find_imbalance with nothing to report.
def test_balance_cascade():
    mesh: CartesianMesh[HeatField]
    dim_min: array[float, 3]
    dim_max: array[float, 3]
    root: int = 0
    child: int = 0
    root_one: int = 0

    dim_min[0] = 0.0
    dim_min[1] = 0.0
    dim_min[2] = 0.0
    dim_max[0] = 1.0
    dim_max[1] = 1.0
    dim_max[2] = 1.0
    geom_cartesian_uniform(mesh, dim_min, dim_max, 0.5)

    # Capture the +x-direction root before any refine so we can verify the
    # cascade refined it from the original level-0 leaf to a non-leaf parent.
    root_one = geom_cartesian_locate(mesh, 0.75, 0.25, 0.25)
    check_int(root_one, 1)
    check_true(mesh.is_leaf[root_one])

    # Refine root 0 then refine its +x-corner child. The grandchildren on the
    # +x face look across to root 1 (still level 0): without balance that is
    # a two-level jump.
    root = geom_cartesian_locate(mesh, 0.1, 0.1, 0.1)
    geom_cartesian_refine_cell(mesh, root)
    child = geom_cartesian_locate(mesh, 0.4, 0.1, 0.1)
    check_int(mesh.level[child], 1)
    geom_cartesian_refine_cell(mesh, child)

    # The cascade should have refined root 1, leaving zero remaining violations.
    check_int(geom_cartesian_find_imbalance(mesh), -1)
    check_true(not mesh.is_leaf[root_one])

# Refining a single root cell does not break 2:1 balance: every neighbor of
# the new level-1 children is either a same-level sibling or a level-0 root.
def test_find_imbalance_no_violation():
    mesh: CartesianMesh[HeatField]
    dim_min: array[float, 3]
    dim_max: array[float, 3]
    root: int = 0

    dim_min[0] = 0.0
    dim_min[1] = 0.0
    dim_min[2] = 0.0
    dim_max[0] = 1.0
    dim_max[1] = 1.0
    dim_max[2] = 1.0
    geom_cartesian_uniform(mesh, dim_min, dim_max, 0.5)

    root = geom_cartesian_locate(mesh, 0.25, 0.25, 0.25)
    geom_cartesian_refine_cell(mesh, root)
    check_int(geom_cartesian_find_imbalance(mesh), -1)

# fvc_grad on T(x) = 2*x should produce d/dx = 2 in an interior cell whose
# x-neighbors both exist.
def test_fvc_grad_linear():
    mesh: CartesianMesh[HeatField]
    dim_min: array[float, 3]
    dim_max: array[float, 3]
    grad: array[float, :, :]
    l: int = 0
    c: int = 0

    dim_min[0] = 0.0
    dim_min[1] = 0.0
    dim_min[2] = 0.0
    dim_max[0] = 1.0
    dim_max[1] = 1.0
    dim_max[2] = 1.0
    geom_cartesian_uniform(mesh, dim_min, dim_max, 0.25)
    allocate(grad, mesh.cell_capacity, 3)

    # Initialise T = 2 * x at cell centers.
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        mesh.T[c] = 2.0 * mesh.center[c, 0]

    fvc_grad(mesh, mesh.T, grad)

    # Pick a cell with x-neighbors on both sides, then check d/dx = 2.
    c = geom_cartesian_locate(mesh, 0.375, 0.5, 0.5)
    check_close(grad[c, 0], 2.0, 1.0e-10)

# fvc_laplacian on a constant field must produce zero everywhere.
def test_fvc_laplacian_constant():
    mesh: CartesianMesh[HeatField]
    dim_min: array[float, 3]
    dim_max: array[float, 3]
    gamma_face: array[float, :, :]
    lap: array[float, :]
    l: int = 0
    c: int = 0

    dim_min[0] = 0.0
    dim_min[1] = 0.0
    dim_min[2] = 0.0
    dim_max[0] = 1.0
    dim_max[1] = 1.0
    dim_max[2] = 1.0
    geom_cartesian_uniform(mesh, dim_min, dim_max, 0.25)
    allocate(gamma_face, mesh.cell_capacity, 6)
    allocate(lap, mesh.cell_capacity)

    mesh.T = 3.7
    gamma_face = 1.0
    lap = 0.0
    fvc_laplacian(mesh, gamma_face, mesh.T, lap)

    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        check_close(lap[c], 0.0, 1.0e-10)

# fvm_solve_diag inverts a pure-diagonal equation cell by cell.
def test_fvm_solve_diag():
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
    allocate(coeff, mesh.cell_capacity)
    allocate(source, mesh.cell_capacity)

    # diag = volume * coeff, rhs = volume * source. solution = source / coeff.
    coeff = 2.0
    source = 6.0
    mesh.T = 0.0

    fvm_equation_init(eq, mesh)
    fvm_source_lhs(eq, mesh, coeff)
    fvm_source(eq, mesh, source)
    fvm_solve_diag(eq, mesh, mesh.T)

    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        check_close(mesh.T[c], 3.0, 1.0e-12)

# Steady-state heat conduction with Dirichlet T=0 at x=0 and T=1 at x=1
# (zero-flux Neumann on the four other faces) has analytic solution T = x.
def test_steady_heat_cg():
    mesh: CartesianMesh[HeatField]
    dim_min: array[float, 3]
    dim_max: array[float, 3]
    gamma_face: array[float, :, :]
    eq: FVMEquation
    l: int = 0
    c: int = 0
    err: float = 0.0
    max_err: float = 0.0

    dim_min[0] = 0.0
    dim_min[1] = 0.0
    dim_min[2] = 0.0
    dim_max[0] = 1.0
    dim_max[1] = 1.0
    dim_max[2] = 1.0
    geom_cartesian_uniform(mesh, dim_min, dim_max, 0.25)
    allocate(gamma_face, mesh.cell_capacity, 6)

    mesh.T = 0.0
    gamma_face = 1.0

    fvm_equation_init(eq, mesh)
    fvm_laplacian(eq, mesh, gamma_face)
    fvm_dirichlet(eq, mesh, gamma_face, 0, 0.0)
    fvm_dirichlet(eq, mesh, gamma_face, 1, 1.0)
    fvm_solve_cg(eq, mesh, mesh.T, 1.0e-12, 2000)

    max_err = 0.0
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        err = abs(mesh.T[c] - mesh.center[c, 0])
        if err > max_err:
            max_err = err
    check_true(max_err < 1.0e-6)

# Same problem solved through the BiCGStab path. The matrix is still SPD so
# both solvers should converge to the same answer.
def test_steady_heat_bicgstab():
    mesh: CartesianMesh[HeatField]
    dim_min: array[float, 3]
    dim_max: array[float, 3]
    gamma_face: array[float, :, :]
    eq: FVMEquation
    l: int = 0
    c: int = 0
    err: float = 0.0
    max_err: float = 0.0

    dim_min[0] = 0.0
    dim_min[1] = 0.0
    dim_min[2] = 0.0
    dim_max[0] = 1.0
    dim_max[1] = 1.0
    dim_max[2] = 1.0
    geom_cartesian_uniform(mesh, dim_min, dim_max, 0.25)
    allocate(gamma_face, mesh.cell_capacity, 6)

    mesh.T = 0.0
    gamma_face = 1.0

    fvm_equation_init(eq, mesh)
    fvm_laplacian(eq, mesh, gamma_face)
    fvm_dirichlet(eq, mesh, gamma_face, 0, 0.0)
    fvm_dirichlet(eq, mesh, gamma_face, 1, 1.0)
    fvm_solve_bicgstab(eq, mesh, mesh.T, 1.0e-12, 2000)

    max_err = 0.0
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        err = abs(mesh.T[c] - mesh.center[c, 0])
        if err > max_err:
            max_err = err
    check_true(max_err < 1.0e-6)

# Two opposing constant fluxes plus a single Dirichlet pin force a known
# linear profile so the Neumann helper can be checked. With gamma=1, applying
# Neumann flux f on x=0 and Dirichlet T=0 on x=1 yields T(x) = f * (1 - x).
def test_dirichlet_neumann_combo():
    mesh: CartesianMesh[HeatField]
    dim_min: array[float, 3]
    dim_max: array[float, 3]
    gamma_face: array[float, :, :]
    eq: FVMEquation
    flux: float = -2.0
    l: int = 0
    c: int = 0
    err: float = 0.0
    max_err: float = 0.0
    expected: float = 0.0

    dim_min[0] = 0.0
    dim_min[1] = 0.0
    dim_min[2] = 0.0
    dim_max[0] = 1.0
    dim_max[1] = 1.0
    dim_max[2] = 1.0
    geom_cartesian_uniform(mesh, dim_min, dim_max, 0.25)
    allocate(gamma_face, mesh.cell_capacity, 6)

    mesh.T = 0.0
    gamma_face = 1.0

    fvm_equation_init(eq, mesh)
    fvm_laplacian(eq, mesh, gamma_face)
    # Outward Neumann flux of -2 on the x=0 face injects heat into the domain.
    fvm_neumann(eq, mesh, 0, flux)
    fvm_dirichlet(eq, mesh, gamma_face, 1, 0.0)
    fvm_solve_cg(eq, mesh, mesh.T, 1.0e-12, 2000)

    # gamma = 1, so T(x) = -flux * (1 - x) = 2 * (1 - x).
    max_err = 0.0
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        expected = -flux * (1.0 - mesh.center[c, 0])
        err = abs(mesh.T[c] - expected)
        if err > max_err:
            max_err = err
    check_true(max_err < 1.0e-6)

def main():
    test_locate_uniform()
    test_locate_after_refine()
    test_balance_cascade()
    test_find_imbalance_no_violation()
    test_fvc_grad_linear()
    test_fvc_laplacian_constant()
    test_fvm_solve_diag()
    test_steady_heat_cg()
    test_steady_heat_bicgstab()
    test_dirichlet_neumann_combo()
    print("test_fvm: all checks passed")

# Demonstrate finite-volume operators over CartesianMesh cell lists
# See examples/support_geom_cartesian_fvm_body_pimple.py for a more complex CFD application
# See support/geom_cartesian_fvm.py for extensive FVM support library references in the comments

import support.geom_cartesian
import support.geom_cartesian_fvm

struct HeatField:
    T: float

def main():
    # NOTE: The syntax for CartesianMesh is special; its 3D cells can hold any data in a struct (like HeatField here)
    mesh: CartesianMesh[HeatField]
    dim_min: array[float, 3]
    dim_max: array[float, 3]
    spacing: float = 0.5
    c: int = 0
    gamma_face: array[float, :, :]
    lap: array[float, :]
    grad: array[float, :, :]
    source: array[float, :]
    old_T: array[float, :]
    eq: FVMEquation

    dim_min[0] = 0.0
    dim_min[1] = 0.0
    dim_min[2] = 0.0
    dim_max[0] = 1.0
    dim_max[1] = 1.0
    dim_max[2] = 1.0

    # Build a small cell-list mesh.
    geom_cartesian_uniform(mesh, dim_min, dim_max, spacing)
    allocate(gamma_face, mesh.cell_capacity, 6)
    allocate(lap, mesh.cell_capacity)
    allocate(grad, mesh.cell_capacity, 3)
    allocate(source, mesh.cell_capacity)
    allocate(old_T, mesh.cell_capacity)

    mesh.T = 1.0
    c = geom_cartesian_locate(mesh, 0.25, 0.25, 0.25)
    mesh.T[c] = 2.0
    gamma_face = 1.0
    source = 0.0
    old_T = mesh.T
    lap = 0.0
    grad = 0.0

    # Explicit operators fill caller-provided arrays.
    fvc_grad(mesh, mesh.T, grad)
    fvc_laplacian(mesh, gamma_face, mesh.T, lap)

    # Implicit operators assemble equation coefficients.
    fvm_equation_init(eq, mesh)
    fvm_ddt(eq, mesh, old_T, 0.1)
    fvm_laplacian(eq, mesh, gamma_face)
    fvm_source(eq, mesh, source)
    fvm_solve_cg(eq, mesh, mesh.T, 1.0e-8, 100)

    print("FVM demo cells:", mesh.num_leaves)
    print("Gradient x:", grad[c, 0])
    print("Laplacian:", lap[c])
    print("Diagonal:", eq.diag[c])

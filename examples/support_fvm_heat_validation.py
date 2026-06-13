# End-to-end FVM validation: steady-state heat conduction on the unit cube.
#
# Solves -laplacian(T) = 0 with Dirichlet boundary conditions
#   T = 0 on the x=0 face
#   T = 1 on the x=1 face
# and homogeneous Neumann (zero flux) on the four remaining faces.
# The analytic solution is the linear profile T(x) = x, so the discrete
# cell-centre values should match x_c to discretisation accuracy.

import support.geom_cartesian
import support.geom_cartesian_fvm

struct HeatField:
    T: float

def main():
    mesh: CartesianMesh[HeatField]
    dim_min: array[float, 3]
    dim_max: array[float, 3]
    spacing: float = 0.125
    gamma_face: array[float, :, :]
    eq: FVMEquation
    l: int = 0
    c: int = 0
    err: float = 0.0
    max_err: float = 0.0
    x_center: float = 0.0
    rms_err: float = 0.0
    # ParaView export buffers: cell-centered fields reshaped to a rank-3
    # (nz, ny, nx) grid with one rectilinear axis per dimension.
    i: int = 0
    j: int = 0
    k: int = 0
    cid: int = 0
    x_coords: array[float, :]
    y_coords: array[float, :]
    z_coords: array[float, :]
    t_grid: array[float, :, :, :]
    t_exact_grid: array[float, :, :, :]
    err_grid: array[float, :, :, :]
    xdmf_xml: string

    # Unit cube domain.
    dim_min[0] = 0.0
    dim_min[1] = 0.0
    dim_min[2] = 0.0
    dim_max[0] = 1.0
    dim_max[1] = 1.0
    dim_max[2] = 1.0

    # Build the uniform cell-list mesh and allocate per-face diffusivity.
    geom_cartesian_uniform(mesh, dim_min, dim_max, spacing)
    allocate(gamma_face, mesh.cell_capacity, 6)

    # Initial guess and uniform unit diffusivity on every face.
    mesh.T = 0.0
    gamma_face = 1.0

    # Assemble the diffusion operator with Dirichlet conditions on the x-faces.
    # The other four boundary faces are left untouched, which is exactly the
    # homogeneous Neumann (zero flux) default.
    fvm_equation_init(eq, mesh)
    fvm_laplacian(eq, mesh, gamma_face)
    fvm_dirichlet(eq, mesh, gamma_face, 0, 0.0)
    fvm_dirichlet(eq, mesh, gamma_face, 1, 1.0)

    # Diffusion with Dirichlet conditions yields a symmetric positive-definite
    # system, so the CG path applies.
    fvm_solve_cg(eq, mesh, mesh.T, 1.0e-12, 2000)

    # Compare cell-centre values to the analytic profile T(x) = x.
    max_err = 0.0
    rms_err = 0.0
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        x_center = mesh.center[c, 0]
        err = abs(mesh.T[c] - x_center)
        if err > max_err:
            max_err = err
        rms_err += err * err

    rms_err = sqrt(rms_err / mesh.num_leaves)

    print("heat validation cells:", mesh.num_leaves)
    print(f"max |T - x|: {max_err:.4e}")
    print(f"rms |T - x|: {rms_err:.4e}")

    # ParaView export. The validation uses a uniform mesh with no
    # refinement, so leaf cells fall on a regular nx*ny*nz grid in
    # x-fastest order and reshape cleanly into a rank-3 array. The xdmf
    # helpers emit node-centered rectilinear topology, so we use cell
    # centers as the coordinate axes.
    x_coords = linspace(dim_min[0] + 0.5 * spacing, dim_max[0] - 0.5 * spacing, mesh.nx)
    y_coords = linspace(dim_min[1] + 0.5 * spacing, dim_max[1] - 0.5 * spacing, mesh.ny)
    z_coords = linspace(dim_min[2] + 0.5 * spacing, dim_max[2] - 0.5 * spacing, mesh.nz)

    allocate(t_grid, mesh.nz, mesh.ny, mesh.nx)
    allocate(t_exact_grid, mesh.nz, mesh.ny, mesh.nx)
    allocate(err_grid, mesh.nz, mesh.ny, mesh.nx)

    # Pack cell-centered T, the analytic profile, and the pointwise error
    # into rank-3 arrays. Cell id ordering is x-fastest.
    for k in range(mesh.nz):
        for j in range(mesh.ny):
            for i in range(mesh.nx):
                cid = (k * mesh.ny + j) * mesh.nx + i
                t_grid[k, j, i] = mesh.T[cid]
                t_exact_grid[k, j, i] = mesh.center[cid, 0]
                err_grid[k, j, i] = abs(mesh.T[cid] - mesh.center[cid, 0])

    # Write the HDF5 payload and the XDMF sidecar that ParaView opens.
    h5write("fvm_heat_validation.h5", "/x", x_coords)
    h5write("fvm_heat_validation.h5", "/y", y_coords)
    h5write("fvm_heat_validation.h5", "/z", z_coords)
    h5write("fvm_heat_validation.h5", "/T", t_grid)
    h5write("fvm_heat_validation.h5", "/T_exact", t_exact_grid)
    h5write("fvm_heat_validation.h5", "/abs_error", err_grid)

    xdmf_add_xyz(xdmf_xml, x_coords, y_coords, z_coords)
    xdmf_add(xdmf_xml, "T", t_grid)
    xdmf_add(xdmf_xml, "T_exact", t_exact_grid)
    xdmf_add(xdmf_xml, "abs_error", err_grid)
    xdmf_write("fvm_heat_validation.xdmf", "fvm_heat_validation.h5", xdmf_xml)

    print("Wrote fvm_heat_validation.h5 and fvm_heat_validation.xdmf")
    print("Open fvm_heat_validation.xdmf in ParaView")

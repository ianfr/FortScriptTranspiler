# Demonstrate the struct-parameterized CartesianMesh[T] API.
#
# The user defines a "field set" struct whose fields name the per-cell
# quantities. The generated Fortran derived type extends the base
# CartesianMesh with one allocatable per field: rank-1 for scalar fields and
# rank-2 for array[float, 3] vector fields.
#
# The primary compiler-lowered built-in is the allocator:
#   geom_cartesian_uniform(mesh, dim_min, dim_max, spacing)
# which inspects the field-set struct and allocates the cell-list arrays.

import support.geom_cartesian

# Field set: two scalars plus a 3-vector.
struct TemperatureFlow:
    temperature: float
    pressure: float
    velocity: array[float, 3]

def main():
    mesh: CartesianMesh[TemperatureFlow]
    dim_min: array[float, 3]
    dim_max: array[float, 3]
    spacing: float = 0.25
    c0: int = 0
    c1: int = 0
    first_child: int = 0
    old_cells: int = 0
    nx_sdf: int = 9
    ny_sdf: int = 9
    nz_sdf: int = 9
    i: int = 0
    j: int = 0
    k: int = 0
    x_coords: array[float, :]
    y_coords: array[float, :]
    z_coords: array[float, :]
    sdf: array[float, :, :, :]

    dim_min[0] = -1.0
    dim_min[1] = -1.0
    dim_min[2] = -1.0
    dim_max[0] = 1.0
    dim_max[1] = 1.0
    dim_max[2] = 1.0

    # Allocates cell-list geometry and one field array per FieldSet member.
    geom_cartesian_uniform(mesh, dim_min, dim_max, spacing)
    print("Mesh shape:", mesh.nx, "x", mesh.ny, "x", mesh.nz)
    print("Leaf cells:", mesh.num_leaves)

    # Whole-field assignment: scalar broadcasts over every cell.
    mesh.temperature = 300.0
    mesh.velocity = 0.0

    # Slice assignment: fill all cells of one field.
    mesh.pressure[:] = 101325.0

    # Cell ids use x-fastest ordering.
    c0 = 0
    c1 = (1 * mesh.ny + 1) * mesh.nx + 1

    # Single-cell index assignment for scalar and vector fields.
    mesh.temperature[c0] = 350.0
    mesh.pressure[c1] = 99000.0
    mesh.velocity[c0, 0] = 1.5

    # mesh.<field> reads work the same way.
    print("Cell c0 temperature:", mesh.temperature[c0])
    print("Cell c1 pressure:   ", mesh.pressure[c1])
    print("Cell c0 velocity x: ", mesh.velocity[c0, 0])
    print("Cell c0 volume:     ", mesh.volume[c0])

    # Refinement appends eight children and inherits field values.
    old_cells = mesh.num_cells
    geom_cartesian_refine_cell(mesh, c0)
    first_child = old_cells
    print("Leaf cells after refine:", mesh.num_leaves)
    print("First child temperature:", mesh.temperature[first_child])

    # Coarsening averages children back into the parent.
    geom_cartesian_coarsen_cell(mesh, c0)
    print("Leaf cells after coarsen:", mesh.num_leaves)

    # Build a simple spherical SDF over the same domain.
    x_coords = linspace(dim_min[0], dim_max[0], nx_sdf)
    y_coords = linspace(dim_min[1], dim_max[1], ny_sdf)
    z_coords = linspace(dim_min[2], dim_max[2], nz_sdf)
    allocate(sdf, nz_sdf, ny_sdf, nx_sdf)
    for k in range(nz_sdf):
        for j in range(ny_sdf):
            for i in range(nx_sdf):
                sdf[k, j, i] = sqrt(
                    x_coords[i] ** 2
                    + y_coords[j] ** 2
                    + z_coords[k] ** 2
                ) - 0.65

    # Refine leaves whose centers are close to the SDF zero surface.
    geom_cartesian_refine_to_sdf(mesh, sdf, 0.2, 1)
    print("Leaf cells after SDF refine:", mesh.num_leaves)

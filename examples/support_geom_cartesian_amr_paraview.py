# Demonstrate ParaView export for a CartesianMesh with adaptive refinement.
#
# Builds a uniform mesh on a cube, refines around a spherical signed
# distance field, then hands the leaf cells to the support library's
# geom_cartesian_leaf_corners / geom_cartesian_leaf_field helpers and the
# xdmf_add_unstructured / xdmf_add_cell builtins to produce an XDMF + HDF5
# pair that ParaView can open directly.
#
# After running:
#   open geom_cartesian_amr.xdmf in ParaView

import support.geom_cartesian

# Per-cell field set: a single scalar storing the signed distance to the
# implicit sphere at each leaf center.
struct AmrField:
    distance: float

def main():
    mesh: CartesianMesh[AmrField]
    dim_min: array[float, 3]
    dim_max: array[float, 3]
    spacing: float = 0.25
    sdf_n: int = 17
    radius: float = 0.55
    refine_tol: float = 0.15
    max_level: int = 2

    # SDF grid covering the same domain as the mesh.
    x_coords: array[float, :]
    y_coords: array[float, :]
    z_coords: array[float, :]
    sdf: array[float, :, :, :]
    i: int = 0
    j: int = 0
    k: int = 0
    l: int = 0
    c: int = 0

    # XDMF / HDF5 buffers. The leaf-corner helper allocates these.
    points: array[float, :, :]
    connectivity: array[int, :, :]
    distance_field: array[float, :]
    xdmf_xml: string

    # Cube centered at the origin.
    dim_min[0] = -1.0
    dim_min[1] = -1.0
    dim_min[2] = -1.0
    dim_max[0] = 1.0
    dim_max[1] = 1.0
    dim_max[2] = 1.0

    # Start with a coarse uniform mesh.
    geom_cartesian_uniform(mesh, dim_min, dim_max, spacing)
    print("Initial leaves:", mesh.num_leaves)

    # Sample a sphere SDF on a regular grid spanning the domain.
    x_coords = linspace(dim_min[0], dim_max[0], sdf_n)
    y_coords = linspace(dim_min[1], dim_max[1], sdf_n)
    z_coords = linspace(dim_min[2], dim_max[2], sdf_n)
    allocate(sdf, sdf_n, sdf_n, sdf_n)
    for k in range(sdf_n):
        for j in range(sdf_n):
            for i in range(sdf_n):
                # Signed distance to a sphere of given radius at the origin.
                sdf[k, j, i] = sqrt(
                    x_coords[i] ** 2
                    + y_coords[j] ** 2
                    + z_coords[k] ** 2
                ) - radius

    # Refine leaves near the sphere surface up to the requested level.
    geom_cartesian_refine_to_sdf(mesh, sdf, refine_tol, max_level)
    print("Leaves after SDF refine:", mesh.num_leaves)

    # Populate the per-cell field with the analytic sphere SDF at each
    # leaf center.
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        mesh.distance[c] = sqrt(
            mesh.center[c, 0] ** 2
            + mesh.center[c, 1] ** 2
            + mesh.center[c, 2] ** 2
        ) - radius

    # Build the unstructured hex geometry and compact the per-cell field
    # to leaf order. The shapes below match the layout the XDMF helpers
    # expect: (3, 8N) for points and (8, N) for connectivity so the bytes
    # land in HDF5 row-major order.
    allocate(points, 3, 8 * mesh.num_leaves)
    allocate(connectivity, 8, mesh.num_leaves)
    allocate(distance_field, mesh.num_leaves)
    geom_cartesian_leaf_corners(mesh, points, connectivity)
    geom_cartesian_leaf_field(mesh, mesh.distance, distance_field)

    # Write the HDF5 payload. The XDMF helpers expect /points and
    # /connectivity at the locations below; attribute datasets follow
    # the name given to xdmf_add_cell.
    h5write("geom_cartesian_amr.h5", "/points", points)
    h5write("geom_cartesian_amr.h5", "/connectivity", connectivity)
    h5write("geom_cartesian_amr.h5", "/distance", distance_field)

    # Assemble the XDMF sidecar: unstructured hex topology + cell scalar.
    xdmf_add_unstructured(xdmf_xml, points, connectivity)
    xdmf_add_cell(xdmf_xml, "distance", distance_field)
    xdmf_write("geom_cartesian_amr.xdmf", "geom_cartesian_amr.h5", xdmf_xml)

    print("Wrote geom_cartesian_amr.h5 and geom_cartesian_amr.xdmf")
    print("Open geom_cartesian_amr.xdmf in ParaView")

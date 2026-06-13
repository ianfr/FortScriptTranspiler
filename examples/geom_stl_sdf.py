# Compute a signed distance field for a small triangle mesh and write it as
# an HDF5 + XDMF pair for ParaView.
#
# The example builds a synthetic unit-cube mesh in code (12 triangles) so it
# runs without an external STL file. To use an external STL instead, replace
# the synthetic-cube block with one of:
#     geom_stl_read_ascii("path/to/mesh.stl", mesh)
#     geom_stl_read_binary("path/to/mesh.stl", mesh)
# (both allocate mesh.* internally).

import support.geom_stl

# Helper: assign one triangle's twelve scalars in one place.
def set_tri(mesh: STLMesh, idx: int,
            nx_: float, ny_: float, nz_: float,
            a0: float, a1: float, a2: float,
            b0: float, b1: float, b2: float,
            c0: float, c1: float, c2: float):
    mesh.normal_x[idx] = nx_
    mesh.normal_y[idx] = ny_
    mesh.normal_z[idx] = nz_
    mesh.v0_x[idx] = a0
    mesh.v0_y[idx] = a1
    mesh.v0_z[idx] = a2
    mesh.v1_x[idx] = b0
    mesh.v1_y[idx] = b1
    mesh.v1_z[idx] = b2
    mesh.v2_x[idx] = c0
    mesh.v2_y[idx] = c1
    mesh.v2_z[idx] = c2

def main():
    mesh: STLMesh
    nx: int = 128
    ny: int = 64
    nz: int = 64
    x_coords: array[float, :]
    y_coords: array[float, :]
    z_coords: array[float, :]
    sdf: array[float, :, :, :]
    xdmf_xml: string

    # Path is resolved relative to the process working directory, not the
    # source file. Run this example from the repo root.
    geom_stl_read_binary("media/jet/jet.stl", mesh)

    geom_stl_compute_bounds(mesh)
    print("Mesh bounding box min:", mesh.min_bound[0], mesh.min_bound[1], mesh.min_bound[2])
    print("Mesh bounding box max:", mesh.max_bound[0], mesh.max_bound[1], mesh.max_bound[2])

    # Slightly larger domain than the mesh
    x_coords = linspace(mesh.min_bound[0]*1.5, mesh.max_bound[0]*1.5, nx)
    y_coords = linspace(mesh.min_bound[1]*1.5, mesh.max_bound[1]*1.5, ny)
    z_coords = linspace(mesh.min_bound[2]*1.5, mesh.max_bound[2]*1.5, nz)
    # Store SDF as z, y, x for XDMF and cartesian sampling.
    allocate(sdf, nz, ny, nx)

    print("Computing SDF...")
    geom_stl_sdf_uniform(mesh, x_coords, y_coords, z_coords, sdf)
    print("Computed SDF on", nx, "x", ny, "x", nz, "grid")

    # Spatial query examples.
    print("Inside (0,0,2)?", geom_stl_inscribed(mesh, 0.0, 0.0, 0.0)) # yes
    print("Inside (0.8,0,1.1)?", geom_stl_inscribed(mesh, 100.0, 0.0, 0.0)) # no

    geom_stl_sdf_write_hdf5(sdf, x_coords, y_coords, z_coords, "geom_stl_sdf.h5")

    xdmf_add_xyz(xdmf_xml, x_coords, y_coords, z_coords)
    xdmf_add(xdmf_xml, "SDF", sdf)
    xdmf_write("geom_stl_sdf.xdmf", "geom_stl_sdf.h5", xdmf_xml)

    print("Wrote geom_stl_sdf.h5 and geom_stl_sdf.xdmf")
    print("Open the .xdmf in ParaView to visualize the SDF.")

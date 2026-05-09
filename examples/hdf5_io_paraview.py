# Write a 3D structured-grid HDF5 file for ParaView via an XDMF sidecar.

def main():
    nx: int = 21  # Grid points along x
    ny: int = 17  # Grid points along y
    nz: int = 13  # Grid points along z
    pi: float = 3.14159265358979  # Trig constant

    x: array[float, :]  # x coordinates
    y: array[float, :]  # y coordinates
    z: array[float, :]  # z coordinates
    p: array[float, :, :, :]  # Scalar field on nodes
    u_mag: array[float, :, :, :]  # Fake velocity magnitude on nodes
    xdmf_xml: string  # XML payload for the XDMF sidecar

    x = linspace(0.0, 2.0, nx)
    y = linspace(0.0, 1.5, ny)
    z = linspace(-0.5, 0.5, nz)

    allocate(p, nz, ny, nx)
    allocate(u_mag, nz, ny, nx)

    for k in range(nz):
        for j in range(ny):
            for i in range(nx):
                # Store the 3D fields in z, y, x order to match XDMF.
                p[k, j, i] = 1.0 + 0.25 * sin(pi * x[i]) * cos(pi * y[j]) + 0.1 * z[k]
                u_mag[k, j, i] = sqrt(
                    (x[i] - 1.0) ** 2
                    + 0.25 * (y[j] - 0.75) ** 2
                    + 4.0 * z[k] ** 2
                )

    h5write("hdf5_paraview_structured.h5", "/x", x)
    h5write("hdf5_paraview_structured.h5", "/y", y)
    h5write("hdf5_paraview_structured.h5", "/z", z)
    h5write("hdf5_paraview_structured.h5", "/p", p)
    h5write("hdf5_paraview_structured.h5", "/u_mag", u_mag)
    print("Wrote hdf5_paraview_structured.h5")

    xdmf_add_xyz(xdmf_xml, x, y, z)
    xdmf_add(xdmf_xml, "p", p)
    xdmf_add(xdmf_xml, "u_mag", u_mag)
    xdmf_write("hdf5_paraview_structured.xdmf", "hdf5_paraview_structured.h5", xdmf_xml)

    print("Wrote hdf5_paraview_structured.xdmf")
    print("Open the hdf5_paraview_structured.xdmf in ParaView")

# FortScript geom_stl support library.
# STL triangle mesh I/O, transforms, signed distance field computation, and
# basic spatial queries. The I/O readers are compiler-lowered stubs backed by
# the hand-written Fortran module support/geom_stl_read.f90.
#
# STLMesh uses parallel arrays for the triangle attributes (twelve scalar
# arrays plus the precomputed bounding box) so that the Fortran reader can
# fill them directly without traversing an array of derived types.

# Off-axis direction used by inside/outside ray casts. The Y and Z components
# are irrational so the ray never lies in the plane of an axis-aligned face
# nor grazes a triangle edge (which would corrupt the Moller-Trumbore parity).
IRR_RAY_Y: float = 0.61803398875
IRR_RAY_Z: float = 0.41421356237

struct STLMesh:
    num_triangles: int
    normal_x: array[float, :]
    normal_y: array[float, :]
    normal_z: array[float, :]
    v0_x: array[float, :]
    v0_y: array[float, :]
    v0_z: array[float, :]
    v1_x: array[float, :]
    v1_y: array[float, :]
    v1_z: array[float, :]
    v2_x: array[float, :]
    v2_y: array[float, :]
    v2_z: array[float, :]
    min_bound: array[float, 3]
    max_bound: array[float, 3]
    center: array[float, 3]

# Allocate all per-triangle arrays in `mesh` to length n_tri. Use this before
# populating mesh fields manually (the read stubs allocate internally).
def geom_stl_init(mesh: STLMesh, n_tri: int):
    nx_buf: array[float, :]
    ny_buf: array[float, :]
    nz_buf: array[float, :]
    v0x_buf: array[float, :]
    v0y_buf: array[float, :]
    v0z_buf: array[float, :]
    v1x_buf: array[float, :]
    v1y_buf: array[float, :]
    v1z_buf: array[float, :]
    v2x_buf: array[float, :]
    v2y_buf: array[float, :]
    v2z_buf: array[float, :]

    allocate(nx_buf, n_tri)
    allocate(ny_buf, n_tri)
    allocate(nz_buf, n_tri)
    allocate(v0x_buf, n_tri)
    allocate(v0y_buf, n_tri)
    allocate(v0z_buf, n_tri)
    allocate(v1x_buf, n_tri)
    allocate(v1y_buf, n_tri)
    allocate(v1z_buf, n_tri)
    allocate(v2x_buf, n_tri)
    allocate(v2y_buf, n_tri)
    allocate(v2z_buf, n_tri)

    mesh.num_triangles = n_tri
    mesh.normal_x = nx_buf
    mesh.normal_y = ny_buf
    mesh.normal_z = nz_buf
    mesh.v0_x = v0x_buf
    mesh.v0_y = v0y_buf
    mesh.v0_z = v0z_buf
    mesh.v1_x = v1x_buf
    mesh.v1_y = v1y_buf
    mesh.v1_z = v1z_buf
    mesh.v2_x = v2x_buf
    mesh.v2_y = v2y_buf
    mesh.v2_z = v2z_buf

# Read an ASCII STL file into `mesh`. The compiler lowers this stub to a call
# into geom_stl_read_mod%fortscript_geom_stl_read_ascii__.
def geom_stl_read_ascii(filename: string, mesh: STLMesh):
    pass  # Compiler stub lowered to support/geom_stl_read.f90.

# Read a binary STL file into `mesh`. The compiler lowers this stub to a call
# into geom_stl_read_mod%fortscript_geom_stl_read_binary__.
def geom_stl_read_binary(filename: string, mesh: STLMesh):
    pass  # Compiler stub lowered to support/geom_stl_read.f90.

# Compute and store the axis-aligned bounding box of the mesh in
# mesh.min_bound, mesh.max_bound, mesh.center. Must be called once after
# reading or transforming the mesh.
def geom_stl_compute_bounds(mesh: STLMesh):
    n: int = mesh.num_triangles
    i: int = 0
    xmin: float = 0.0
    ymin: float = 0.0
    zmin: float = 0.0
    xmax: float = 0.0
    ymax: float = 0.0
    zmax: float = 0.0

    if n <= 0:
        mesh.min_bound[0] = 0.0
        mesh.min_bound[1] = 0.0
        mesh.min_bound[2] = 0.0
        mesh.max_bound[0] = 0.0
        mesh.max_bound[1] = 0.0
        mesh.max_bound[2] = 0.0
        mesh.center[0] = 0.0
        mesh.center[1] = 0.0
        mesh.center[2] = 0.0
        return

    xmin = mesh.v0_x[0]
    ymin = mesh.v0_y[0]
    zmin = mesh.v0_z[0]
    xmax = xmin
    ymax = ymin
    zmax = zmin

    for i in range(n):
        # Vertex 0
        xmin = min(xmin, mesh.v0_x[i])
        ymin = min(ymin, mesh.v0_y[i])
        zmin = min(zmin, mesh.v0_z[i])
        xmax = max(xmax, mesh.v0_x[i])
        ymax = max(ymax, mesh.v0_y[i])
        zmax = max(zmax, mesh.v0_z[i])
        # Vertex 1
        xmin = min(xmin, mesh.v1_x[i])
        ymin = min(ymin, mesh.v1_y[i])
        zmin = min(zmin, mesh.v1_z[i])
        xmax = max(xmax, mesh.v1_x[i])
        ymax = max(ymax, mesh.v1_y[i])
        zmax = max(zmax, mesh.v1_z[i])
        # Vertex 2
        xmin = min(xmin, mesh.v2_x[i])
        ymin = min(ymin, mesh.v2_y[i])
        zmin = min(zmin, mesh.v2_z[i])
        xmax = max(xmax, mesh.v2_x[i])
        ymax = max(ymax, mesh.v2_y[i])
        zmax = max(zmax, mesh.v2_z[i])

    mesh.min_bound[0] = xmin
    mesh.min_bound[1] = ymin
    mesh.min_bound[2] = zmin
    mesh.max_bound[0] = xmax
    mesh.max_bound[1] = ymax
    mesh.max_bound[2] = zmax
    mesh.center[0] = 0.5 * (xmin + xmax)
    mesh.center[1] = 0.5 * (ymin + ymax)
    mesh.center[2] = 0.5 * (zmin + zmax)

# Translate every vertex of the mesh by (tx, ty, tz). Modifies in place.
def geom_stl_translate(mesh: STLMesh, tx: float, ty: float, tz: float):
    n: int = mesh.num_triangles
    i: int = 0

    for i in range(n):
        mesh.v0_x[i] += tx
        mesh.v0_y[i] += ty
        mesh.v0_z[i] += tz
        mesh.v1_x[i] += tx
        mesh.v1_y[i] += ty
        mesh.v1_z[i] += tz
        mesh.v2_x[i] += tx
        mesh.v2_y[i] += ty
        mesh.v2_z[i] += tz

    # Bounding box shifts by the same offset; cheaper than recomputing.
    mesh.min_bound[0] += tx
    mesh.min_bound[1] += ty
    mesh.min_bound[2] += tz
    mesh.max_bound[0] += tx
    mesh.max_bound[1] += ty
    mesh.max_bound[2] += tz
    mesh.center[0] += tx
    mesh.center[1] += ty
    mesh.center[2] += tz

# Scale every vertex of the mesh uniformly about the origin. Modifies in place.
def geom_stl_scale(mesh: STLMesh, s: float):
    n: int = mesh.num_triangles
    i: int = 0

    for i in range(n):
        mesh.v0_x[i] *= s
        mesh.v0_y[i] *= s
        mesh.v0_z[i] *= s
        mesh.v1_x[i] *= s
        mesh.v1_y[i] *= s
        mesh.v1_z[i] *= s
        mesh.v2_x[i] *= s
        mesh.v2_y[i] *= s
        mesh.v2_z[i] *= s

    geom_stl_compute_bounds(mesh)

# Rotate the mesh in place by `angle` radians about the unit-vector axis
# (ax, ay, az) using Rodrigues' formula. Normals rotate with vertices.
def geom_stl_rotate(mesh: STLMesh, angle: float, ax: float, ay: float, az: float):
    n: int = mesh.num_triangles
    i: int = 0
    c: float = cos(angle)
    s: float = sin(angle)
    t: float = 1.0 - c
    # Rotation matrix entries.
    r00: float = t * ax * ax + c
    r01: float = t * ax * ay - s * az
    r02: float = t * ax * az + s * ay
    r10: float = t * ax * ay + s * az
    r11: float = t * ay * ay + c
    r12: float = t * ay * az - s * ax
    r20: float = t * ax * az - s * ay
    r21: float = t * ay * az + s * ax
    r22: float = t * az * az + c
    x: float = 0.0
    y: float = 0.0
    z: float = 0.0

    for i in range(n):
        # Vertex 0
        x = mesh.v0_x[i]
        y = mesh.v0_y[i]
        z = mesh.v0_z[i]
        mesh.v0_x[i] = r00 * x + r01 * y + r02 * z
        mesh.v0_y[i] = r10 * x + r11 * y + r12 * z
        mesh.v0_z[i] = r20 * x + r21 * y + r22 * z
        # Vertex 1
        x = mesh.v1_x[i]
        y = mesh.v1_y[i]
        z = mesh.v1_z[i]
        mesh.v1_x[i] = r00 * x + r01 * y + r02 * z
        mesh.v1_y[i] = r10 * x + r11 * y + r12 * z
        mesh.v1_z[i] = r20 * x + r21 * y + r22 * z
        # Vertex 2
        x = mesh.v2_x[i]
        y = mesh.v2_y[i]
        z = mesh.v2_z[i]
        mesh.v2_x[i] = r00 * x + r01 * y + r02 * z
        mesh.v2_y[i] = r10 * x + r11 * y + r12 * z
        mesh.v2_z[i] = r20 * x + r21 * y + r22 * z
        # Normal
        x = mesh.normal_x[i]
        y = mesh.normal_y[i]
        z = mesh.normal_z[i]
        mesh.normal_x[i] = r00 * x + r01 * y + r02 * z
        mesh.normal_y[i] = r10 * x + r11 * y + r12 * z
        mesh.normal_z[i] = r20 * x + r21 * y + r22 * z

    geom_stl_compute_bounds(mesh)

# Squared Euclidean distance from a point to a single triangle, computed by
# projecting onto the triangle plane and clamping in barycentric coords.
# Used as a building block for the SDF.
def geom_stl_point_tri_dist2(px: float, py: float, pz: float,
                             ax: float, ay: float, az: float,
                             bx: float, by: float, bz: float,
                             cx: float, cy: float, cz: float) -> float:
    abx: float = bx - ax
    aby: float = by - ay
    abz: float = bz - az
    acx: float = cx - ax
    acy: float = cy - ay
    acz: float = cz - az
    apx: float = px - ax
    apy: float = py - ay
    apz: float = pz - az

    d1: float = abx * apx + aby * apy + abz * apz
    d2: float = acx * apx + acy * apy + acz * apz

    # Region 1: closest to vertex A
    if d1 <= 0.0 and d2 <= 0.0:
        return apx * apx + apy * apy + apz * apz

    bpx: float = px - bx
    bpy: float = py - by
    bpz: float = pz - bz
    d3: float = abx * bpx + aby * bpy + abz * bpz
    d4: float = acx * bpx + acy * bpy + acz * bpz

    # Region 2: closest to vertex B
    if d3 >= 0.0 and d4 <= d3:
        return bpx * bpx + bpy * bpy + bpz * bpz

    vc: float = d1 * d4 - d3 * d2

    # Region 3: closest to edge AB
    if vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0:
        v: float = d1 / (d1 - d3)
        qx: float = ax + v * abx - px
        qy: float = ay + v * aby - py
        qz: float = az + v * abz - pz
        return qx * qx + qy * qy + qz * qz

    cpx: float = px - cx
    cpy: float = py - cy
    cpz: float = pz - cz
    d5: float = abx * cpx + aby * cpy + abz * cpz
    d6: float = acx * cpx + acy * cpy + acz * cpz

    # Region 4: closest to vertex C
    if d6 >= 0.0 and d5 <= d6:
        return cpx * cpx + cpy * cpy + cpz * cpz

    vb: float = d5 * d2 - d1 * d6
    # Region 5: closest to edge AC
    if vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0:
        w: float = d2 / (d2 - d6)
        qx2: float = ax + w * acx - px
        qy2: float = ay + w * acy - py
        qz2: float = az + w * acz - pz
        return qx2 * qx2 + qy2 * qy2 + qz2 * qz2

    va: float = d3 * d6 - d5 * d4
    # Region 6: closest to edge BC
    if va <= 0.0 and (d4 - d3) >= 0.0 and (d5 - d6) >= 0.0:
        u: float = (d4 - d3) / ((d4 - d3) + (d5 - d6))
        qx3: float = bx + u * (cx - bx) - px
        qy3: float = by + u * (cy - by) - py
        qz3: float = bz + u * (cz - bz) - pz
        return qx3 * qx3 + qy3 * qy3 + qz3 * qz3

    # Region 0: interior projection onto the triangle plane.
    denom: float = 1.0 / (va + vb + vc)
    vv: float = vb * denom
    ww: float = vc * denom
    qx4: float = ax + abx * vv + acx * ww - px
    qy4: float = ay + aby * vv + acy * ww - py
    qz4: float = az + abz * vv + acz * ww - pz
    return qx4 * qx4 + qy4 * qy4 + qz4 * qz4

# Test whether a ray from (ox, oy, oz) along (dx, dy, dz) intersects the
# triangle (a, b, c). Returns 1 if it does (with positive ray parameter),
# 0 otherwise. Moeller-Trumbore algorithm.
def geom_stl_ray_tri_hit(ox: float, oy: float, oz: float,
                         dx: float, dy: float, dz: float,
                         ax: float, ay: float, az: float,
                         bx: float, by: float, bz: float,
                         cx: float, cy: float, cz: float) -> int:
    eps: float = 1.0e-12
    e1x: float = bx - ax
    e1y: float = by - ay
    e1z: float = bz - az
    e2x: float = cx - ax
    e2y: float = cy - ay
    e2z: float = cz - az
    # h = d x e2
    hx: float = dy * e2z - dz * e2y
    hy: float = dz * e2x - dx * e2z
    hz: float = dx * e2y - dy * e2x
    a_dot: float = e1x * hx + e1y * hy + e1z * hz

    if abs(a_dot) < eps:
        return 0  # Ray parallel to triangle.

    f: float = 1.0 / a_dot
    sx: float = ox - ax
    sy: float = oy - ay
    sz: float = oz - az
    u: float = f * (sx * hx + sy * hy + sz * hz)
    if u < 0.0 or u > 1.0:
        return 0

    # q = s x e1
    qx: float = sy * e1z - sz * e1y
    qy: float = sz * e1x - sx * e1z
    qz: float = sx * e1y - sy * e1x
    v: float = f * (dx * qx + dy * qy + dz * qz)
    if v < 0.0 or u + v > 1.0:
        return 0

    t: float = f * (e2x * qx + e2y * qy + e2z * qz)
    if t > eps:
        return 1
    return 0

# Count the number of triangles intersected by the ray from (ox, oy, oz)
# along direction (dx, dy, dz). Used to determine inside/outside in the SDF.
def geom_stl_ray_count(mesh: STLMesh,
                       ox: float, oy: float, oz: float,
                       dx: float, dy: float, dz: float) -> int:
    n: int = mesh.num_triangles
    i: int = 0
    hits: int = 0

    for i in range(n):
        hits += geom_stl_ray_tri_hit(ox, oy, oz, dx, dy, dz,
                                     mesh.v0_x[i], mesh.v0_y[i], mesh.v0_z[i],
                                     mesh.v1_x[i], mesh.v1_y[i], mesh.v1_z[i],
                                     mesh.v2_x[i], mesh.v2_y[i], mesh.v2_z[i])
    return hits

# Check whether a query point is inside the (closed, manifold) mesh by ray
# casting along +X and counting intersections. Odd = inside.
def geom_stl_inscribed(mesh: STLMesh, qx: float, qy: float, qz: float) -> bool:
    # Use an irrational off-axis ray so we don't graze axis-aligned mesh edges
    # (rays along +X miss both triangles of a face split along the YZ diagonal).
    hits: int = geom_stl_ray_count(mesh, qx, qy, qz, 1.0, IRR_RAY_Y, IRR_RAY_Z)
    return (hits % 2) == 1

# Triangle bin grid for SDF acceleration. The grid spans the STL bounding
# box with a small relative margin and bins triangles into a uniform 3D
# voxel structure. The flat CSR-style arrays (offsets, tri_ids) hold the
# list of triangle indices touching each bin. Per-triangle axis-aligned
# bounding box arrays are precomputed so the ray-cast sign test can skip
# triangles whose AABB does not intersect the query ray.
struct STLBins:
    nbin: int
    bin_min: array[float, 3]
    bin_dx: float
    inv_bin_dx: float
    offsets: array[int, :]
    tri_ids: array[int, :]
    tri_xmin: array[float, :]
    tri_ymin: array[float, :]
    tri_zmin: array[float, :]
    tri_xmax: array[float, :]
    tri_ymax: array[float, :]
    tri_zmax: array[float, :]

# Build a uniform bin grid over the mesh AABB. `nbin` selects the number of
# bins along each axis; total bin count is nbin**3. Each bin owns the list
# of triangle ids whose AABB intersects it. Call once per mesh before
# `geom_stl_sdf_uniform` (which builds its own internal bins when called
# directly; expose this when reusing a bin grid across multiple SDFs).
def geom_stl_build_bins(mesh: STLMesh, nbin: int, bins: STLBins):
    n: int = mesh.num_triangles
    nbin3: int = nbin * nbin * nbin
    t: int = 0
    ii: int = 0
    jj: int = 0
    kk: int = 0
    i0: int = 0
    i1: int = 0
    j0: int = 0
    j1: int = 0
    k0: int = 0
    k1: int = 0
    idx: int = 0
    cursor: int = 0
    total: int = 0
    span_x: float = 0.0
    span_y: float = 0.0
    span_z: float = 0.0
    max_span: float = 0.0
    margin: float = 0.01
    bdx: float = 0.0
    inv_bdx: float = 0.0
    bx_min: float = 0.0
    by_min: float = 0.0
    bz_min: float = 0.0
    tx_min: float = 0.0
    ty_min: float = 0.0
    tz_min: float = 0.0
    tx_max: float = 0.0
    ty_max: float = 0.0
    tz_max: float = 0.0
    counts: array[int, :]
    offs: array[int, :]
    tri_buf: array[int, :]
    tx_minin_buf: array[float, :]
    ty_minin_buf: array[float, :]
    tz_minin_buf: array[float, :]
    tx_minax_buf: array[float, :]
    ty_minax_buf: array[float, :]
    tz_minax_buf: array[float, :]

    # Cubic bin grid sized so a single edge length covers the longest mesh
    # axis. Using a single bin size keeps shell expansion isotropic and
    # makes the distance lower-bound formula trivial.
    span_x = mesh.max_bound[0] - mesh.min_bound[0]
    span_y = mesh.max_bound[1] - mesh.min_bound[1]
    span_z = mesh.max_bound[2] - mesh.min_bound[2]
    max_span = span_x
    if span_y > max_span:
        max_span = span_y
    if span_z > max_span:
        max_span = span_z
    # Floor to a positive value so degenerate (planar) meshes still bin.
    if max_span <= 0.0:
        max_span = 1.0
    bdx = max_span * (1.0 + 2.0 * margin) / nbin
    inv_bdx = 1.0 / bdx
    # Origin places the mesh AABB centered in the bin grid.
    bx_min = 0.5 * (mesh.min_bound[0] + mesh.max_bound[0]) - 0.5 * nbin * bdx
    by_min = 0.5 * (mesh.min_bound[1] + mesh.max_bound[1]) - 0.5 * nbin * bdx
    bz_min = 0.5 * (mesh.min_bound[2] + mesh.max_bound[2]) - 0.5 * nbin * bdx

    bins.nbin = nbin
    bins.bin_dx = bdx
    bins.inv_bin_dx = inv_bdx
    bins.bin_min[0] = bx_min
    bins.bin_min[1] = by_min
    bins.bin_min[2] = bz_min

    # Per-triangle AABBs feed the ray prefilter and the bin overlap loop.
    allocate(tx_minin_buf, n)
    allocate(ty_minin_buf, n)
    allocate(tz_minin_buf, n)
    allocate(tx_minax_buf, n)
    allocate(ty_minax_buf, n)
    allocate(tz_minax_buf, n)
    for t in range(n):
        tx_min = min(min(mesh.v0_x[t], mesh.v1_x[t]), mesh.v2_x[t])
        ty_min = min(min(mesh.v0_y[t], mesh.v1_y[t]), mesh.v2_y[t])
        tz_min = min(min(mesh.v0_z[t], mesh.v1_z[t]), mesh.v2_z[t])
        tx_max = max(max(mesh.v0_x[t], mesh.v1_x[t]), mesh.v2_x[t])
        ty_max = max(max(mesh.v0_y[t], mesh.v1_y[t]), mesh.v2_y[t])
        tz_max = max(max(mesh.v0_z[t], mesh.v1_z[t]), mesh.v2_z[t])
        tx_minin_buf[t] = tx_min
        ty_minin_buf[t] = ty_min
        tz_minin_buf[t] = tz_min
        tx_minax_buf[t] = tx_max
        ty_minax_buf[t] = ty_max
        tz_minax_buf[t] = tz_max
    bins.tri_xmin = tx_minin_buf
    bins.tri_ymin = ty_minin_buf
    bins.tri_zmin = tz_minin_buf
    bins.tri_xmax = tx_minax_buf
    bins.tri_ymax = ty_minax_buf
    bins.tri_zmax = tz_minax_buf

    # Pass 1: count how many triangles touch each bin.
    allocate(counts, nbin3)
    for idx in range(nbin3):
        counts[idx] = 0
    for t in range(n):
        i0 = floor((tx_minin_buf[t] - bx_min) * inv_bdx)
        i1 = floor((tx_minax_buf[t] - bx_min) * inv_bdx)
        j0 = floor((ty_minin_buf[t] - by_min) * inv_bdx)
        j1 = floor((ty_minax_buf[t] - by_min) * inv_bdx)
        k0 = floor((tz_minin_buf[t] - bz_min) * inv_bdx)
        k1 = floor((tz_minax_buf[t] - bz_min) * inv_bdx)
        if i0 < 0:
            i0 = 0
        if j0 < 0:
            j0 = 0
        if k0 < 0:
            k0 = 0
        if i1 > nbin - 1:
            i1 = nbin - 1
        if j1 > nbin - 1:
            j1 = nbin - 1
        if k1 > nbin - 1:
            k1 = nbin - 1
        for kk in range(k0, k1 + 1):
            for jj in range(j0, j1 + 1):
                for ii in range(i0, i1 + 1):
                    idx = (kk * nbin + jj) * nbin + ii
                    counts[idx] += 1

    # Prefix sum into a CSR-style offset table.
    allocate(offs, nbin3 + 1)
    offs[0] = 0
    for idx in range(nbin3):
        offs[idx + 1] = offs[idx] + counts[idx]
    total = offs[nbin3]
    if total < 1:
        total = 1
    allocate(tri_buf, total)
    # Reset counts to act as a per-bin write cursor in pass 2.
    for idx in range(nbin3):
        counts[idx] = 0

    # Pass 2: scatter triangle ids into the flat list.
    for t in range(n):
        i0 = floor((tx_minin_buf[t] - bx_min) * inv_bdx)
        i1 = floor((tx_minax_buf[t] - bx_min) * inv_bdx)
        j0 = floor((ty_minin_buf[t] - by_min) * inv_bdx)
        j1 = floor((ty_minax_buf[t] - by_min) * inv_bdx)
        k0 = floor((tz_minin_buf[t] - bz_min) * inv_bdx)
        k1 = floor((tz_minax_buf[t] - bz_min) * inv_bdx)
        if i0 < 0:
            i0 = 0
        if j0 < 0:
            j0 = 0
        if k0 < 0:
            k0 = 0
        if i1 > nbin - 1:
            i1 = nbin - 1
        if j1 > nbin - 1:
            j1 = nbin - 1
        if k1 > nbin - 1:
            k1 = nbin - 1
        for kk in range(k0, k1 + 1):
            for jj in range(j0, j1 + 1):
                for ii in range(i0, i1 + 1):
                    idx = (kk * nbin + jj) * nbin + ii
                    cursor = offs[idx] + counts[idx]
                    tri_buf[cursor] = t
                    counts[idx] += 1

    bins.offsets = offs
    bins.tri_ids = tri_buf

# Compute the signed distance field over a uniform 3D grid sampled from the
# mesh. The SDF is positive outside, negative inside. Internally builds a
# triangle bin grid (see `STLBins`) and walks bins outward from each query
# point until the current best squared distance is smaller than the next
# shell's lower bound, then uses a per-triangle AABB ray-slab prefilter to
# count parity for the inside/outside sign. Cost is roughly O((nx*ny*nz) *
# (tris_per_bin * shells + n_tri_filtered)) instead of the brute-force
# O(n_tri * nx*ny*nz). Outer loops run under @par.
# Signed distance at one point against a prebuilt bin grid. Returns the
# unsigned nearest-triangle distance with a sign from an off-axis ray parity
# count (negative inside). Pure, so it can be called inside @par loops. Build
# `bins` once with geom_stl_build_bins and reuse it across every query point.
def geom_stl_sdf_point(mesh: STLMesh,
                       bins: STLBins,
                       px: float,
                       py: float,
                       pz: float) -> float:
    n: int = mesh.num_triangles
    t: int = 0
    r: int = 0
    ib: int = 0
    jb: int = 0
    kb: int = 0
    bx: int = 0
    by: int = 0
    bz: int = 0
    di: int = 0
    dj: int = 0
    dk: int = 0
    mx: int = 0
    idx: int = 0
    off: int = 0
    off_lo: int = 0
    off_hi: int = 0
    hits: int = 0
    d2: float = 0.0
    best: float = 0.0
    lb: float = 0.0
    sign_val: float = 1.0
    bx_min: float = bins.bin_min[0]
    by_min: float = bins.bin_min[1]
    bz_min: float = bins.bin_min[2]
    bdx: float = bins.bin_dx
    inv_bdx: float = bins.inv_bin_dx
    nb_int: int = bins.nbin
    # Ray prefilter scratch.
    rdy: float = IRR_RAY_Y
    rdz: float = IRR_RAY_Z
    inv_rdy: float = 1.0 / IRR_RAY_Y
    inv_rdz: float = 1.0 / IRR_RAY_Z
    t_lo: float = 0.0
    t_hi: float = 0.0
    tlx: float = 0.0
    thx: float = 0.0
    tly: float = 0.0
    thy: float = 0.0
    tlz: float = 0.0
    thz: float = 0.0
    # Moller-Trumbore scratch.
    e1x: float = 0.0
    e1y: float = 0.0
    e1z: float = 0.0
    e2x: float = 0.0
    e2y: float = 0.0
    e2z: float = 0.0
    hx: float = 0.0
    hy: float = 0.0
    hz: float = 0.0
    a_dot: float = 0.0
    inv_a: float = 0.0
    sx: float = 0.0
    sy: float = 0.0
    sz: float = 0.0
    qx: float = 0.0
    qy: float = 0.0
    qz: float = 0.0
    uu: float = 0.0
    vv: float = 0.0
    tt: float = 0.0

    # Locate the query inside the bin grid (clamped at edges).
    bx = floor((px - bx_min) * inv_bdx)
    by = floor((py - by_min) * inv_bdx)
    bz = floor((pz - bz_min) * inv_bdx)
    if bx < 0:
        bx = 0
    if by < 0:
        by = 0
    if bz < 0:
        bz = 0
    if bx > nb_int - 1:
        bx = nb_int - 1
    if by > nb_int - 1:
        by = nb_int - 1
    if bz > nb_int - 1:
        bz = nb_int - 1

    # Shell-expansion nearest-distance search.
    # Once best squared distance is smaller than the next shell's squared
    # lower bound, later shells short-circuit at the `lb*lb <= best` gate and
    # only the empty outer iteration runs.
    best = 1.0e30
    for r in range(nb_int + 1):
        if r == 0:
            lb = 0.0
        else:
            lb = (r - 1) * bdx
        if lb * lb <= best:
            for kb in range(bz - r, bz + r + 1):
                for jb in range(by - r, by + r + 1):
                    for ib in range(bx - r, bx + r + 1):
                        # Restrict to the Chebyshev shell of radius r.
                        di = abs(ib - bx)
                        dj = abs(jb - by)
                        dk = abs(kb - bz)
                        mx = di
                        if dj > mx:
                            mx = dj
                        if dk > mx:
                            mx = dk
                        if mx == r:
                            if ib >= 0 and ib < nb_int and jb >= 0 and jb < nb_int and kb >= 0 and kb < nb_int:
                                idx = (kb * nb_int + jb) * nb_int + ib
                                off_lo = bins.offsets[idx]
                                off_hi = bins.offsets[idx + 1]
                                for off in range(off_lo, off_hi):
                                    t = bins.tri_ids[off]
                                    d2 = geom_stl_point_tri_dist2(px, py, pz,
                                        mesh.v0_x[t], mesh.v0_y[t], mesh.v0_z[t],
                                        mesh.v1_x[t], mesh.v1_y[t], mesh.v1_z[t],
                                        mesh.v2_x[t], mesh.v2_y[t], mesh.v2_z[t])
                                    if d2 < best:
                                        best = d2

    # Inside/outside sign by inlined off-axis Moller-Trumbore.
    # Prefilter every triangle with an AABB-ray slab test so the expensive
    # intersection arithmetic only runs for triangles whose AABB actually
    # intersects the ray.
    hits = 0
    for t in range(n):
        # x-slab: ray-x grows by 1 per unit t, only forward (t >= 0).
        if bins.tri_xmax[t] >= px:
            tlx = bins.tri_xmin[t] - px
            if tlx < 0.0:
                tlx = 0.0
            thx = bins.tri_xmax[t] - px
            # y-slab: rdy is a fixed positive constant.
            tly = (bins.tri_ymin[t] - py) * inv_rdy
            thy = (bins.tri_ymax[t] - py) * inv_rdy
            # z-slab: rdz is a fixed positive constant.
            tlz = (bins.tri_zmin[t] - pz) * inv_rdz
            thz = (bins.tri_zmax[t] - pz) * inv_rdz
            t_lo = tlx
            if tly > t_lo:
                t_lo = tly
            if tlz > t_lo:
                t_lo = tlz
            t_hi = thx
            if thy < t_hi:
                t_hi = thy
            if thz < t_hi:
                t_hi = thz
            if t_lo <= t_hi:
                # Triangle AABB intersects the forward ray window; run the
                # exact intersection. Moller-Trumbore inlined.
                e1x = mesh.v1_x[t] - mesh.v0_x[t]
                e1y = mesh.v1_y[t] - mesh.v0_y[t]
                e1z = mesh.v1_z[t] - mesh.v0_z[t]
                e2x = mesh.v2_x[t] - mesh.v0_x[t]
                e2y = mesh.v2_y[t] - mesh.v0_y[t]
                e2z = mesh.v2_z[t] - mesh.v0_z[t]
                hx = rdy * e2z - rdz * e2y
                hy = rdz * e2x - 1.0 * e2z
                hz = 1.0 * e2y - rdy * e2x
                a_dot = e1x * hx + e1y * hy + e1z * hz
                if abs(a_dot) >= 1.0e-12:
                    inv_a = 1.0 / a_dot
                    sx = px - mesh.v0_x[t]
                    sy = py - mesh.v0_y[t]
                    sz = pz - mesh.v0_z[t]
                    uu = inv_a * (sx * hx + sy * hy + sz * hz)
                    if uu >= 0.0 and uu <= 1.0:
                        qx = sy * e1z - sz * e1y
                        qy = sz * e1x - sx * e1z
                        qz = sx * e1y - sy * e1x
                        vv = inv_a * (1.0 * qx + rdy * qy + rdz * qz)
                        if vv >= 0.0 and (uu + vv) <= 1.0:
                            tt = inv_a * (e2x * qx + e2y * qy + e2z * qz)
                            if tt > 1.0e-12:
                                hits += 1

    if (hits % 2) == 1:
        sign_val = -1.0
    else:
        sign_val = 1.0
    return sign_val * sqrt(best)

# Pick a bin resolution that yields roughly a handful of triangles per bin.
# The stepped lookup avoids a cbrt call and keeps nbin in a range where the
# shell expansion converges in a small constant of iterations for typical
# surface meshes.
def geom_stl_sdf_nbin(n_tri: int) -> int:
    nbin: int = 8
    if n_tri > 64:
        nbin = 12
    if n_tri > 512:
        nbin = 16
    if n_tri > 4096:
        nbin = 24
    if n_tri > 32768:
        nbin = 32
    if n_tri > 131072:
        nbin = 48
    if n_tri > 524288:
        nbin = 64
    return nbin

def geom_stl_sdf_uniform(mesh: STLMesh,
                         x_coords: array[float, :],
                         y_coords: array[float, :],
                         z_coords: array[float, :],
                         sdf: array[float, :, :, :]):
    bins: STLBins
    nx: int = size(x_coords)
    ny: int = size(y_coords)
    nz: int = size(z_coords)
    k: int = 0
    j: int = 0
    i: int = 0

    # Build the acceleration structure once, then sample every grid node with
    # the shared point query.
    geom_stl_build_bins(mesh, geom_stl_sdf_nbin(mesh.num_triangles), bins)

    @par
    for k in range(nz):
        for j in range(ny):
            for i in range(nx):
                sdf[k, j, i] = geom_stl_sdf_point(mesh, bins,
                                                  x_coords[i], y_coords[j], z_coords[k])

# Write the SDF and its coordinate axes to an HDF5 file.
def geom_stl_sdf_write_hdf5(sdf: array[float, :, :, :],
                            x_coords: array[float, :],
                            y_coords: array[float, :],
                            z_coords: array[float, :],
                            filename: string):
    # Use /x, /y, /z because xdmf_add_xyz hard-codes those dataset paths.
    h5write(filename, "/x", x_coords)
    h5write(filename, "/y", y_coords)
    h5write(filename, "/z", z_coords)
    h5write(filename, "/SDF", sdf)

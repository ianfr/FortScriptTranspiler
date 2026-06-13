# FortScript geom_cartesian support library.
#
# 3D cartesian mesh with struct-parameterized field sets.
#
# The user defines a "field set" struct whose members name the per-cell
# quantities and writes `mesh: CartesianMesh[FieldSet]`. The transpiler
# monomorphizes one Fortran derived type per instantiation: the generated
# type extends `CartesianMesh` (so the metadata fields below remain
# accessible) and adds one allocatable per FieldSet field (rank-1 for
# scalar fields, rank-2 for `array[float, 3]` vector fields).
#
# Field reads and writes use direct struct access:
#
#   mesh.temperature = 300.0             # broadcast scalar to every cell
#   mesh.pressure[:] = 101325.0          # fill via slice
#   mesh.temperature[c] = 350.0          # single-cell write
#   val = mesh.temperature[c]            # single-cell read
#
# See examples/geom_cartesian_demo.py and LANGUAGE.md for the full layout
# and index conventions.

struct CartesianMesh:
    # Grid resolution.
    nx: int
    ny: int
    nz: int
    # Cell storage counts.
    num_cells: int
    num_leaves: int
    cell_capacity: int
    # Domain extents and cell spacing.
    dom_min: array[float, 3]
    dom_max: array[float, 3]
    spacing: float
    # Active leaf cell ids.
    leaf_ids: array[int, :]
    # Per-cell geometry.
    level: array[int, :]
    center: array[float, :, :]
    dx: array[float, :]
    volume: array[float, :]
    face_area: array[float, :, :]
    # Per-cell tree topology.
    parent: array[int, :]
    children: array[int, :, :]
    is_leaf: array[bool, :]
    # Per-face neighbor ids.
    neighbor: array[int, :, :, :]

# Build a uniform cell-list mesh covering [dim_min, dim_max] with cells of
# side `spacing`. Compiler-lowered: the transpiler emits metadata writes,
# geometry and topology allocation, neighbor construction, and one `allocate`
# per FieldSet field. Calling this on a non-templated CartesianMesh is a
# compile-time error.
def geom_cartesian_uniform(mesh: CartesianMesh,
                           dim_min: array[float, 3],
                           dim_max: array[float, 3],
                           spacing: float):
    pass  # body emitted by the transpiler based on the FieldSet struct

# Refine one active leaf cell into eight children.
def geom_cartesian_refine_cell(mesh: CartesianMesh,
                               cell_id: int):
    pass  # body emitted by the transpiler based on the FieldSet struct

# Refine leaves near an SDF zero surface up to max_level.
def geom_cartesian_refine_to_sdf(mesh: CartesianMesh,
                                 sdf: array[float, :, :, :],
                                 tol: float,
                                 max_level: int):
    pass  # body emitted by the transpiler based on the FieldSet struct

# Batched refinement of every leaf whose per-cell SDF magnitude is within tol
# up to max_level, in the style of snappyHexMesh castellation. sdf is a
# cell-id-indexed scalar field already sampled at leaf centers (for example
# mesh.sdf filled by geom_cartesian_sample_sdf). Each pass marks the band
# leaves, propagates 2:1 balance over the marked set, splits all marked cells
# in one batch, then rebuilds the leaf list and neighbor table once. Passes
# repeat until no cell is marked. This is the fast replacement for refining
# one cell at a time.
def geom_cartesian_refine_band(mesh: CartesianMesh,
                               sdf: array[float, :],
                               tol: float,
                               max_level: int):
    pass  # body emitted by the transpiler based on the FieldSet struct

# Coarsen a parent whose eight children are active leaves.
def geom_cartesian_coarsen_cell(mesh: CartesianMesh,
                                cell_id: int):
    pass  # body emitted by the transpiler based on the FieldSet struct

# Scan every active leaf looking for a face neighbor whose level is more than
# one below the leaf's level. Returns the 0-based id of the first coarser
# neighbor that must be refined to restore the 2:1 balance rule, or -1 when
# every leaf already satisfies the rule. Used by the lowered refine helpers
# to drive the balance cascade.
def geom_cartesian_find_imbalance(mesh: CartesianMesh) -> int:
    l: int = 0
    c: int = 0
    f: int = 0
    s: int = 0
    nbr: int = 0
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        for f in range(6):
            for s in range(4):
                nbr = mesh.neighbor[c, f, s]
                if nbr >= 0:
                    if mesh.level[c] - mesh.level[nbr] > 1:
                        if mesh.is_leaf[nbr]:
                            return nbr
    return -1

# Rebuild the per-face neighbor table for every active leaf by point-location
# probing instead of an all-pairs overlap scan. For each leaf face the four
# sub-quadrant points just outside the face are located in the tree. A coarser
# or equal neighbor maps all four probes to the same id (filling the four
# slots identically), while up to four finer neighbors each fill one slot.
# Probes outside the domain return -1, marking a boundary face. The probe
# offsets scale with the local cell width, so the result is exact for a 2:1
# graded cartesian mesh. Cost is O(num_leaves * tree_depth), replacing the
# previous O(num_leaves^2) scan.
def geom_cartesian_rebuild_neighbors(mesh: CartesianMesh):
    l: int = 0
    c: int = 0
    f: int = 0
    s: int = 0
    q: float = 0.0     # quarter of the cell width
    nrm: float = 0.0   # outward normal offset past the face
    sa: float = 0.0    # first tangential offset
    sb: float = 0.0    # second tangential offset
    cx: float = 0.0
    cy: float = 0.0
    cz: float = 0.0
    px: float = 0.0
    py: float = 0.0
    pz: float = 0.0

    # Clear every slot; leaves below refill their own faces, non-leaves stay -1.
    mesh.neighbor = -1

    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        cx = mesh.center[c, 0]
        cy = mesh.center[c, 1]
        cz = mesh.center[c, 2]
        q = 0.25 * mesh.dx[c]
        # 0.75*dx lands just inside any face neighbor, coarser or finer.
        nrm = 3.0 * q
        for f in range(6):
            for s in range(4):
                # Pick the four sub-quadrant probe points from the two bits of s.
                if (s == 1) or (s == 3):
                    sa = q
                else:
                    sa = -q
                if (s == 2) or (s == 3):
                    sb = q
                else:
                    sb = -q
                # Offset along the face normal axis; the other two carry sa, sb.
                px = cx
                py = cy
                pz = cz
                if f == 0:
                    px = cx - nrm
                    py = cy + sa
                    pz = cz + sb
                elif f == 1:
                    px = cx + nrm
                    py = cy + sa
                    pz = cz + sb
                elif f == 2:
                    px = cx + sa
                    py = cy - nrm
                    pz = cz + sb
                elif f == 3:
                    px = cx + sa
                    py = cy + nrm
                    pz = cz + sb
                elif f == 4:
                    px = cx + sa
                    py = cy + sb
                    pz = cz - nrm
                else:
                    px = cx + sa
                    py = cy + sb
                    pz = cz + nrm
                mesh.neighbor[c, f, s] = geom_cartesian_locate(mesh, px, py, pz)

# Classify a face neighbor relation for same-level uniform meshes.
def geom_cartesian_face_neighbor_kind(mesh: CartesianMesh,
                                      c: int,
                                      face: int) -> int:
    # Boundary faces have no neighbor id.
    if mesh.neighbor[c, face, 0] < 0:
        return 3
    # Body emitted by the transpiler for level-aware cases.
    return 0

# Fill the world-space center of one face on cell c.
def geom_cartesian_face_center(mesh: CartesianMesh,
                               c: int,
                               face: int,
                               fc: array[float, 3]):
    # Start with the cell center.
    fc[0] = mesh.center[c, 0]
    fc[1] = mesh.center[c, 1]
    fc[2] = mesh.center[c, 2]
    if face == 0:
        fc[0] -= 0.5 * mesh.dx[c]
    elif face == 1:
        fc[0] += 0.5 * mesh.dx[c]
    elif face == 2:
        fc[1] -= 0.5 * mesh.dx[c]
    elif face == 3:
        fc[1] += 0.5 * mesh.dx[c]
    elif face == 4:
        fc[2] -= 0.5 * mesh.dx[c]
    else:
        fc[2] += 0.5 * mesh.dx[c]

# Fill the outward unit normal for a cartesian face.
def geom_cartesian_face_normal(face: int, n: array[float, 3]):
    # Reset all components before assigning the face axis.
    n[0] = 0.0
    n[1] = 0.0
    n[2] = 0.0
    if face == 0:
        n[0] = -1.0
    elif face == 1:
        n[0] = 1.0
    elif face == 2:
        n[1] = -1.0
    elif face == 3:
        n[1] = 1.0
    elif face == 4:
        n[2] = -1.0
    else:
        n[2] = 1.0

# Locate the active leaf cell containing a world-space point. Computes the
# root cell from the uniform grid spacing, then descends through children
# using the same Morton-style octant ordering as geom_cartesian_refine_cell
# until it reaches an active leaf. Returns -1 when the point is outside the
# domain.
def geom_cartesian_locate(mesh: CartesianMesh,
                          x: float,
                          y: float,
                          z: float) -> int:
    i: int = 0
    j: int = 0
    k: int = 0
    c: int = 0
    q: int = 0
    nxt: int = 0

    # Reject points outside the closed-open domain extents.
    if x < mesh.dom_min[0]:
        return -1
    if y < mesh.dom_min[1]:
        return -1
    if z < mesh.dom_min[2]:
        return -1
    if x >= mesh.dom_min[0] + mesh.nx * mesh.spacing:
        return -1
    if y >= mesh.dom_min[1] + mesh.ny * mesh.spacing:
        return -1
    if z >= mesh.dom_min[2] + mesh.nz * mesh.spacing:
        return -1

    # Compute the 0-based root cell id via integer floor of the local index.
    i = floor((x - mesh.dom_min[0]) / mesh.spacing)
    j = floor((y - mesh.dom_min[1]) / mesh.spacing)
    k = floor((z - mesh.dom_min[2]) / mesh.spacing)
    c = (k * mesh.ny + j) * mesh.nx + i

    # Descend until c is an active leaf or the children chain ends.
    while c >= 0 and c < mesh.num_cells:
        if mesh.is_leaf[c]:
            return c
        # Octant index follows refine_cell: bit 0 = x half, bit 1 = y, bit 2 = z.
        q = 0
        if x >= mesh.center[c, 0]:
            q += 1
        if y >= mesh.center[c, 1]:
            q += 2
        if z >= mesh.center[c, 2]:
            q += 4
        nxt = mesh.children[c, q]
        if nxt < 0:
            return c
        c = nxt
    return c

# Fill caller-provided rank-1 arrays cx, cy, cz with the cell-center
# coordinates. Caller must allocate cx/cy/cz to lengths nx/ny/nz.
def geom_cartesian_centers(mesh: CartesianMesh,
                           cx: array[float, :],
                           cy: array[float, :],
                           cz: array[float, :]):
    i: int = 0
    j: int = 0
    k: int = 0
    dx: float = mesh.spacing

    for i in range(mesh.nx):
        cx[i] = mesh.dom_min[0] + (i + 0.5) * dx
    for j in range(mesh.ny):
        cy[j] = mesh.dom_min[1] + (j + 0.5) * dx
    for k in range(mesh.nz):
        cz[k] = mesh.dom_min[2] + (k + 0.5) * dx

# Fill caller-provided arrays with the eight corner vertices and the hex
# connectivity of every active leaf cell, in the VTK_HEXAHEDRON node order
# expected by XDMF unstructured hex topology. Corners are duplicated per
# cell so refinement-induced hanging nodes do not need to be reconciled.
# Callers must allocate points with Fortran shape (3, 8 * num_leaves) and
# connectivity with Fortran shape (8, num_leaves). The dimensions are
# arranged so the bytes h5fortran writes are already in HDF5 row-major
# order, which is what xdmf_add_unstructured and ParaView read. Pair with
# the xdmf_add_unstructured / xdmf_add_cell builtins to export a
# CartesianMesh.
def geom_cartesian_leaf_corners(mesh: CartesianMesh,
                                points: array[float, :, :],
                                connectivity: array[int, :, :]):
    l: int = 0
    c: int = 0
    base: int = 0
    q: int = 0
    half: float = 0.0
    sx: float = 0.0
    sy: float = 0.0
    sz: float = 0.0

    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        half = 0.5 * mesh.dx[c]
        base = 8 * l
        for q in range(8):
            # VTK hex octant signs: bit 0 = +x, bit 1 = +y, bit 2 = +z.
            if (q == 1) or (q == 2) or (q == 5) or (q == 6):
                sx = 1.0
            else:
                sx = -1.0
            if (q == 2) or (q == 3) or (q == 6) or (q == 7):
                sy = 1.0
            else:
                sy = -1.0
            if q >= 4:
                sz = 1.0
            else:
                sz = -1.0
            # Lay out the (x, y, z) triple in the fast Fortran axis so the
            # bytes on disk are point0_xyz, point1_xyz, ... in HDF5 order.
            points[0, base + q] = mesh.center[c, 0] + sx * half
            points[1, base + q] = mesh.center[c, 1] + sy * half
            points[2, base + q] = mesh.center[c, 2] + sz * half
            connectivity[q, l] = base + q

# Compact a cell-capacity-sized scalar field down to one entry per active
# leaf, in leaf_ids order. The destination matches the cell ordering that
# geom_cartesian_leaf_corners produces, so the pair can be handed straight
# to xdmf_add_cell for ParaView export. Caller must allocate dst to length
# num_leaves before calling.
def geom_cartesian_leaf_field(mesh: CartesianMesh,
                              src: array[float, :],
                              dst: array[float, :]):
    l: int = 0

    for l in range(mesh.num_leaves):
        dst[l] = src[mesh.leaf_ids[l]]

# Sample a rectilinear SDF grid at every active leaf cell center using
# trilinear interpolation. The grid must use z-major storage order:
# sdf_grid[k_z, j_y, i_x] = SDF at (x_sdf[i], y_sdf[j], z_sdf[k]).
# This matches the convention required by geom_cartesian_refine_to_sdf.
# nx_sdf, ny_sdf, nz_sdf are the number of grid points in each direction.
# x_sdf, y_sdf, and z_sdf must be uniformly spaced.
# sdf_out must be allocated to mesh.cell_capacity before calling.
def geom_cartesian_sample_sdf(mesh: CartesianMesh,
                               x_sdf: array[float, :],
                               y_sdf: array[float, :],
                               z_sdf: array[float, :],
                               sdf_grid: array[float, :, :, :],
                               nx_sdf: int,
                               ny_sdf: int,
                               nz_sdf: int,
                               sdf_out: array[float, :]):
    l: int = 0
    c: int = 0
    i0: int = 0
    j0: int = 0
    k0: int = 0
    cx: float = 0.0
    cy: float = 0.0
    cz: float = 0.0
    dx_s: float = 0.0
    dy_s: float = 0.0
    dz_s: float = 0.0
    tx: float = 0.0
    ty: float = 0.0
    tz: float = 0.0
    s000: float = 0.0
    s100: float = 0.0
    s010: float = 0.0
    s110: float = 0.0
    s001: float = 0.0
    s101: float = 0.0
    s011: float = 0.0
    s111: float = 0.0
    s00: float = 0.0
    s10: float = 0.0
    s01: float = 0.0
    s11: float = 0.0
    s0: float = 0.0
    s1: float = 0.0

    dx_s = x_sdf[1] - x_sdf[0]
    dy_s = y_sdf[1] - y_sdf[0]
    dz_s = z_sdf[1] - z_sdf[0]

    @par
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        cx = mesh.center[c, 0]
        cy = mesh.center[c, 1]
        cz = mesh.center[c, 2]
        # Bracket index, clamped to valid interpolation range [0, n-2]
        i0 = floor((cx - x_sdf[0]) / dx_s)
        j0 = floor((cy - y_sdf[0]) / dy_s)
        k0 = floor((cz - z_sdf[0]) / dz_s)
        if i0 < 0:
            i0 = 0
        if i0 > nx_sdf - 2:
            i0 = nx_sdf - 2
        if j0 < 0:
            j0 = 0
        if j0 > ny_sdf - 2:
            j0 = ny_sdf - 2
        if k0 < 0:
            k0 = 0
        if k0 > nz_sdf - 2:
            k0 = nz_sdf - 2
        # Fractional weights, clamped to [0, 1]
        tx = (cx - x_sdf[i0]) / dx_s
        ty = (cy - y_sdf[j0]) / dy_s
        tz = (cz - z_sdf[k0]) / dz_s
        if tx < 0.0:
            tx = 0.0
        if tx > 1.0:
            tx = 1.0
        if ty < 0.0:
            ty = 0.0
        if ty > 1.0:
            ty = 1.0
        if tz < 0.0:
            tz = 0.0
        if tz > 1.0:
            tz = 1.0
        # Corner values from z-major grid: sdf_grid[k, j, i]
        s000 = sdf_grid[k0, j0, i0]
        s100 = sdf_grid[k0, j0, i0 + 1]
        s010 = sdf_grid[k0, j0 + 1, i0]
        s110 = sdf_grid[k0, j0 + 1, i0 + 1]
        s001 = sdf_grid[k0 + 1, j0, i0]
        s101 = sdf_grid[k0 + 1, j0, i0 + 1]
        s011 = sdf_grid[k0 + 1, j0 + 1, i0]
        s111 = sdf_grid[k0 + 1, j0 + 1, i0 + 1]
        # Trilinear interpolation
        s00 = (1.0 - tx) * s000 + tx * s100
        s10 = (1.0 - tx) * s010 + tx * s110
        s01 = (1.0 - tx) * s001 + tx * s101
        s11 = (1.0 - tx) * s011 + tx * s111
        s0 = (1.0 - ty) * s00 + ty * s10
        s1 = (1.0 - ty) * s01 + ty * s11
        sdf_out[c] = (1.0 - tz) * s0 + tz * s1

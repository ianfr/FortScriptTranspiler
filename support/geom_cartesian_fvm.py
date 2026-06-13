# FortScript finite-volume operators for support.geom_cartesian.
#
# NOTE: The FortScript FVM support library module is under active development and still needs end-to-end V&V
#
# NOTE: The use of OpenMP (`@omp`) with FortScript is generally discouraged since 'do concurrent' (`@par`) is safer with GCC
#
# The API follows the OpenFOAM split between explicit fvc-style operators
# that fill output fields and implicit fvm-style operators that assemble an
# equation object.
# https://doc.cfd.direct/notes/cfd-general-principles/equation-discretisation

# Helpful FVM references:
# - Versteeg, H. K., & Malalasekera, W. (2007). An Introduction to Computational Fluid Dynamics: The Finite Volume Method (2nd ed.). Pearson Education
# - https://doc.cfd.direct/notes/cfd-general-principles/numerical-method
# - https://www.tfd.chalmers.se/~hani/kurser/OS_CFD_2008/programmersGuide.pdf
# - https://cpp.openfoam.org/v13/namespaceFoam_1_1fvm.html
# - https://cpp.openfoam.org/v13/namespaceFoam_1_1fvc.html
# - incompressibleFluid Directory Reference: https://cpp.openfoam.org/v13/dir_9aa7d9a7d72e413df139157783bef6c9.html

# Meshing related references:
# - https://www.openfoam.com/documentation/user-guide/4-mesh-generation-and-conversion/4.4-mesh-generation-with-the-snappyhexmesh-utility
# - https://github.com/OpenFOAM/OpenFOAM-13/blob/master/applications/utilities/mesh/generation/snappyHexMesh/snappyHexMesh.C
# - "MW": Maertens, A.P. and Weymouth, G.D. (2015) Accurate Cartesian-grid simulations of near-body flows at intermediate Reynolds numbers. Computer Methods in Applied Mechanics and Engineering, 283, 106-129. (doi:10.1016/j.cma.2014.09.007).
#   - https://eprints.soton.ac.uk/369635/1/Maertens2014_20CMAME.pdf

import support.geom_cartesian
import support.geom_stl
import support.sparse

struct FVMEquation:
    # Cell-id indexed equation storage.
    n_rows: int
    diag: array[float, :]
    offdiag: array[float, :, :, :]
    rhs: array[float, :]

# Allocate an equation builder over the mesh cell-id space.
def fvm_equation_init(eq: FVMEquation,
                      mesh: CartesianMesh):
    pass  # body emitted by the transpiler for struct component allocation

# Reset all equation coefficients without reallocating.
def fvm_equation_zero(eq: FVMEquation):
    eq.diag = 0.0
    eq.offdiag = 0.0
    eq.rhs = 0.0

# Explicit first time derivative over active leaves
# Takes in a field before and after a timestep
# Forward difference
def fvc_ddt(mesh: CartesianMesh,
            field_old: array[float, :],
            field_new: array[float, :],
            dt: float,
            ddt_out: array[float, :]):
    c: int = 0
    # Iterate the dense cell-id space and guard on is_leaf so the output write is
    # indexed directly by the loop variable, keeping GCC do concurrent autopar
    # affine (the leaf_ids gather would make the write a non-affine scatter).
    @par
    for c in range(mesh.cell_capacity):
        if mesh.is_leaf[c]:
            ddt_out[c] = (field_new[c] - field_old[c]) / dt

# Explicit second time derivative over active leaves
# 2nd-order central difference 
def fvc_d2dt2(mesh: CartesianMesh,
              field_oldest: array[float, :],
              field_old: array[float, :],
              field_new: array[float, :],
              dt: float,
              d2_out: array[float, :]):
    c: int = 0
    inv_dt2: float = 1.0 / (dt * dt)
    # See fvc_ddt for is_leaf check info
    @par
    for c in range(mesh.cell_capacity):
        if mesh.is_leaf[c]:
            d2_out[c] = (field_new[c] - 2.0 * field_old[c] + field_oldest[c]) * inv_dt2

# Linear cell-to-face interpolation for scalar fields.
def fvc_interpolate(mesh: CartesianMesh,
                    field: array[float, :],
                    face_field_out: array[float, :, :]):
    l: int = 0
    c: int = 0
    f: int = 0
    nbr: int = 0
    # Neighbor-gather reads (field[nbr]) can't be parallelized by GCC do concurrent.
    # We use an OpenMP parallel do instead
    @omp
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        for f in range(6):
            nbr = mesh.neighbor[c, f, 0]
            if nbr >= 0:
                face_field_out[c, f] = 0.5 * (field[c] + field[nbr])
            else:
                face_field_out[c, f] = field[c]

# Divergence of a scalar face-flux field.
# The divergence is the sum of all outward face fluxes divided by cell volume
#   https://doc.cfd.direct/notes/cfd-general-principles/conservation-of-mass
# phi_face uses the outward flux convention: phi > 0 means outward from cell c.
def fvc_div_flux(mesh: CartesianMesh,
                 phi_face: array[float, :, :],
                 div_out: array[float, :]):
    c: int = 0
    flux_sum: float = 0.0
    # See fvc_ddt for is_leaf check info
    @par
    for c in range(mesh.cell_capacity):
        if mesh.is_leaf[c]:
            flux_sum = phi_face[c, 0] + phi_face[c, 1]
            flux_sum += phi_face[c, 2] + phi_face[c, 3]
            flux_sum += phi_face[c, 4] + phi_face[c, 5]
            div_out[c] = flux_sum / mesh.volume[c]

# Area represented by one neighbor slot on a face
# c: cell id
# f: face index
# s: split level
def fvc_face_slot_area(mesh: CartesianMesh,
                       c: int,
                       f: int,
                       s: int) -> float:
    first_nbr: int = 0
    q: int = 0
    split_face: bool = False

    first_nbr = mesh.neighbor[c, f, 0]
    for q in range(1, 4):
        if mesh.neighbor[c, f, q] != first_nbr:
            split_face = True

    # A split face has one quarter-area slot per probe.
    if split_face:
        return 0.25 * mesh.face_area[c, f]

    # Same-level, coarser-neighbor, and boundary faces use slot 0 only.
    if s == 0:
        return mesh.face_area[c, f]
    return 0.0

# Explicit divergence of a cell-centered vector field
# dUx/dx + dUy/dy + dUz/dz
def fvc_div(mesh: CartesianMesh,
            vector_field: array[float, :, :],
            div_out: array[float, :]):
    l: int = 0
    c: int = 0
    nbr: int = 0
    ux_m: float = 0.0
    ux_p: float = 0.0
    uy_m: float = 0.0
    uy_p: float = 0.0
    uz_m: float = 0.0
    uz_p: float = 0.0
    # See OpenMP note in fvc_interpolate
    @omp
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        ux_m = vector_field[c, 0] # minus side
        ux_p = vector_field[c, 0] # plus side
        uy_m = vector_field[c, 1]
        uy_p = vector_field[c, 1]
        uz_m = vector_field[c, 2]
        uz_p = vector_field[c, 2]
        nbr = mesh.neighbor[c, 0, 0]
        if nbr >= 0:
            ux_m = 0.5 * (vector_field[c, 0] + vector_field[nbr, 0])
        nbr = mesh.neighbor[c, 1, 0]
        if nbr >= 0:
            ux_p = 0.5 * (vector_field[c, 0] + vector_field[nbr, 0])
        nbr = mesh.neighbor[c, 2, 0]
        if nbr >= 0:
            uy_m = 0.5 * (vector_field[c, 1] + vector_field[nbr, 1])
        nbr = mesh.neighbor[c, 3, 0]
        if nbr >= 0:
            uy_p = 0.5 * (vector_field[c, 1] + vector_field[nbr, 1])
        nbr = mesh.neighbor[c, 4, 0]
        if nbr >= 0:
            uz_m = 0.5 * (vector_field[c, 2] + vector_field[nbr, 2])
        nbr = mesh.neighbor[c, 5, 0]
        if nbr >= 0:
            uz_p = 0.5 * (vector_field[c, 2] + vector_field[nbr, 2])

        # NOTE: 1/dx assumes cubic cells
        div_out[c] = ((ux_p - ux_m) + (uy_p - uy_m) + (uz_p - uz_m)) / mesh.dx[c]

# Cell-centered gradient of a scalar field.
# scalar field to vector field; U -> (dU/dx, dU/dy, dU/dz)
# See https://doc.cfd.direct/notes/cfd-general-principles/time-derivatives
def fvc_grad(mesh: CartesianMesh,
             field: array[float, :],
             grad_out: array[float, :, :]):
    l: int = 0
    c: int = 0
    nbr: int = 0
    vm: float = 0.0
    vp: float = 0.0
    # See OpenMP note in fvc_interpolate
    @omp
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]

        # X
        vm = field[c] # minus side
        vp = field[c] # plus side
        nbr = mesh.neighbor[c, 0, 0]
        if nbr >= 0:
            vm = field[nbr]
        nbr = mesh.neighbor[c, 1, 0]
        if nbr >= 0:
            vp = field[nbr]
        grad_out[c, 0] = (vp - vm) / (2.0 * mesh.dx[c])

        # Y
        vm = field[c]
        vp = field[c]
        nbr = mesh.neighbor[c, 2, 0]
        if nbr >= 0:
            vm = field[nbr]
        nbr = mesh.neighbor[c, 3, 0]
        if nbr >= 0:
            vp = field[nbr]
        grad_out[c, 1] = (vp - vm) / (2.0 * mesh.dx[c])

        # Z
        vm = field[c]
        vp = field[c]
        nbr = mesh.neighbor[c, 4, 0]
        if nbr >= 0:
            vm = field[nbr]
        nbr = mesh.neighbor[c, 5, 0]
        if nbr >= 0:
            vp = field[nbr]
        grad_out[c, 2] = (vp - vm) / (2.0 * mesh.dx[c])

# Explicit Laplacian of a scalar field
# Versteeg eq. 4.60 (divided by volume)
#   fvm_laplacian corresponds to eq 4.61 assembled (not this function, this is fvc)
# div(grad(field))
# gamma_face: diffusion coefficient; TODO actually could be removed maybe?
def fvc_laplacian(mesh: CartesianMesh,
                  gamma_face: array[float, :, :],
                  field: array[float, :],
                  lap_out: array[float, :]):
    l: int = 0
    c: int = 0
    f: int = 0
    s: int = 0
    nbr: int = 0
    coeff: float = 0.0
    dcenters: float = 0.0
    slot_area: float = 0.0
    accum: float = 0.0
    # See OpenMP note in fvc_interpolate
    @omp
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        accum = 0.0
        for f in range(6):
            for s in range(4):
                nbr = mesh.neighbor[c, f, s]
                slot_area = fvc_face_slot_area(mesh, c, f, s)
                if nbr >= 0 and slot_area > 0.0:
                    # (field[nbr] - field[c]) / dcenters: face-normal component of grad(field)
                    dcenters = 0.5 * (mesh.dx[c] + mesh.dx[nbr])
                    coeff = gamma_face[c, f] * slot_area / dcenters
                    accum += coeff * (field[nbr] - field[c])
        lap_out[c] = accum / mesh.volume[c]

# Add an implicit first time derivative
# Only impacts the diagonal of the LHS since no spatial neighbors involved
# See OpenFoam's EulerDdtScheme: https://github.com/OpenFOAM/OpenFOAM-13/blob/19a3d5400c8c936e24745f5cbfce8906084d2621/src/finiteVolume/finiteVolume/ddtSchemes/EulerDdtScheme/EulerDdtScheme.C#L289
def fvm_ddt(eq: FVMEquation,
            mesh: CartesianMesh,
            field_old: array[float, :],
            dt: float):
    c: int = 0
    coeff: float = 0.0
    # TODO Retry @par once gfortran can parallelize writes through a derived-type allocatable component
    @omp
    for c in range(mesh.cell_capacity):
        if mesh.is_leaf[c]:
            coeff = mesh.volume[c] / dt
            eq.diag[c] += coeff
            eq.rhs[c] += coeff * field_old[c]

# Add an implicit second time derivative
# Only impacts the diagonal of the LHS since no spatial neighbors involved
# See OpenFoam's EulerD2dt2Scheme: https://github.com/OpenFOAM/OpenFOAM-13/blob/19a3d5400c8c936e24745f5cbfce8906084d2621/src/finiteVolume/finiteVolume/d2dt2Schemes/EulerD2dt2Scheme/EulerD2dt2Scheme.C#L251
def fvm_d2dt2(eq: FVMEquation,
              mesh: CartesianMesh,
              field_oldest: array[float, :],
              field_old: array[float, :],
              dt: float):
    c: int = 0
    coeff: float = 0.0
    # TODO Retry @par once gfortran can parallelize writes through a derived-type allocatable component
    @omp
    for c in range(mesh.cell_capacity):
        if mesh.is_leaf[c]:
            coeff = mesh.volume[c] / (dt * dt)
            eq.diag[c] += coeff
            eq.rhs[c] += coeff * (2.0 * field_old[c] - field_oldest[c])

# Add a source coefficient to the LHS diagonal
def fvm_source_lhs(eq: FVMEquation,
           mesh: CartesianMesh,
           coeff_field: array[float, :]):
    c: int = 0
    # TODO Retry @par once gfortran can parallelize writes through a derived-type allocatable component
    @omp
    for c in range(mesh.cell_capacity):
        if mesh.is_leaf[c]:
            eq.diag[c] += coeff_field[c] * mesh.volume[c]

# Add a volumetric source to the RHS
def fvm_source(eq: FVMEquation,
               mesh: CartesianMesh,
               source_field: array[float, :]):
    c: int = 0
    # TODO Retry @par once gfortran can parallelize writes through a derived-type allocatable component
    @omp
    for c in range(mesh.cell_capacity):
        if mesh.is_leaf[c]:
            eq.rhs[c] += source_field[c] * mesh.volume[c]

# Add a scaled field contribution to the RHS
def fvm_add_to_rhs(eq: FVMEquation,
                   mesh: CartesianMesh,
                   scale: float,
                   field: array[float, :]):
    c: int = 0
    # TODO Retry @par once gfortran can parallelize writes through a derived-type allocatable component
    @omp
    for c in range(mesh.cell_capacity):
        if mesh.is_leaf[c]:
            eq.rhs[c] += scale * field[c] * mesh.volume[c]

# Apply a Dirichlet condition on every boundary face whose face index matches face_sel
# Fixed value; https://doc.cfd.direct/notes/cfd-general-principles/fixed-value-and-fixed-gradient
# face_sel = -1 -> apply on every external face regardless of orientation.
# LHS: add gamma * area / (dx/2) to diagonal
# RHS: add (same) * boundary value
# NOTE: Should be called after fvm_laplacian so the diffusion stencil is in place for the interior faces.
def fvm_dirichlet(eq: FVMEquation,
                  mesh: CartesianMesh,
                  gamma_face: array[float, :, :],
                  face_sel: int,
                  value: float):
    l: int = 0
    c: int = 0
    f: int = 0
    coeff: float = 0.0
    half_dx: float = 0.0
    # TODO Retry @par once gfortran can parallelize writes through a derived-type allocatable component
    @omp
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        for f in range(6):
            if mesh.neighbor[c, f, 0] < 0:
                if face_sel < 0 or f == face_sel:
                    # Ghost-cell extrapolation: boundary lies a half cell from the centre.
                    half_dx = 0.5 * mesh.dx[c]
                    coeff = gamma_face[c, f] * mesh.face_area[c, f] / half_dx
                    eq.diag[c] += coeff # TODO should this be negative? See https://github.com/OpenFOAM/OpenFOAM-13/blob/master/src/finiteVolume/fields/fvPatchFields/basic/fixedValue/fixedValueFvPatchField.C
                    eq.rhs[c] += coeff * value

# Apply a Neumann flux condition on every boundary face whose face index matches face_sel
# Fixed-gradient; https://doc.cfd.direct/notes/cfd-general-principles/fixed-value-and-fixed-gradient
# face_sel = -1 -> apply on every external face regardless of orientation.
# RHS only
# Might be useful: https://github.com/OpenFOAM/OpenFOAM-13/blob/master/src/finiteVolume/fields/fvPatchFields/basic/fixedGradient/fixedGradientFvPatchField.C
def fvm_neumann(eq: FVMEquation,
                mesh: CartesianMesh,
                face_sel: int,
                flux: float):
    l: int = 0
    c: int = 0
    f: int = 0
    # TODO Retry @par once gfortran can parallelize writes through a derived-type allocatable component
    @omp
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        for f in range(6):
            if mesh.neighbor[c, f, 0] < 0:
                if face_sel < 0 or f == face_sel:
                    # Outward Neumann flux contributes -flux * area to the cell residual,
                    # which moves to the right-hand side with the opposite sign.
                    eq.rhs[c] -= flux * mesh.face_area[c, f]

# Add a two-point implicit Laplacian stencil
# See Versteeg eq 4.61
# See fvc_laplacian above
# NOTE the off-diagnonal entries
def fvm_laplacian(eq: FVMEquation,
                  mesh: CartesianMesh,
                  gamma_face: array[float, :, :]):
    l: int = 0
    c: int = 0
    f: int = 0
    s: int = 0
    nbr: int = 0
    coeff: float = 0.0
    dcenters: float = 0.0
    slot_area: float = 0.0
    # TODO Retry @par once gfortran can parallelize writes through a derived-type allocatable component
    @omp
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        for f in range(6):
            for s in range(4):
                nbr = mesh.neighbor[c, f, s]
                slot_area = fvc_face_slot_area(mesh, c, f, s)
                if nbr >= 0 and slot_area > 0.0:
                    dcenters = 0.5 * (mesh.dx[c] + mesh.dx[nbr])
                    coeff = gamma_face[c, f] * slot_area / dcenters
                    eq.diag[c] += coeff
                    eq.offdiag[c, f, s] -= coeff

# Add an upwind implicit convection stencil
# See https://doc.cfd.direct/notes/cfd-general-principles/upwind-scheme
#   "The advantage of upwind is that it can guarantee boundedness of a field..."
# Versteeg: Section 5.6
#   "The upwind differencing or 'donor cell' differencing scheme 
#    takes into account the flow direction when determining the value at a cell face..."
def fvm_div(eq: FVMEquation,
            mesh: CartesianMesh,
            phi_face: array[float, :, :]):
    l: int = 0
    c: int = 0
    f: int = 0
    s: int = 0
    nbr: int = 0
    phi: float = 0.0
    slot_area: float = 0.0
    # TODO Retry @par once gfortran can parallelize writes through a derived-type allocatable component
    @omp
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        for f in range(6): # face loop
            for s in range(4): # safe because fvc_face_slot_area rets 0 if face not needed
                nbr = mesh.neighbor[c, f, s]
                slot_area = fvc_face_slot_area(mesh, c, f, s)
                if slot_area > 0.0:
                    phi = phi_face[c, f] * slot_area / mesh.face_area[c, f]
                    if phi >= 0.0: 
                        eq.diag[c] += phi # outflow: upwind value is from cell c itself
                    elif nbr >= 0:
                        eq.offdiag[c, f, s] += phi # inflow: upwind value is the neighbor

# See fvm_div above
# Add known-value inflow contributions for an upwind convection stencil
def fvm_div_dirichlet(eq: FVMEquation,
                      mesh: CartesianMesh,
                      phi_face: array[float, :, :],
                      face_sel: int,
                      value: float):
    l: int = 0
    c: int = 0
    f: int = 0
    phi: float = 0.0
    # Boundary inflow is a known upwind value and moves to the RHS
    # TODO Retry @par once gfortran can parallelize writes through a derived-type allocatable component
    @omp
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        for f in range(6):
            if mesh.neighbor[c, f, 0] < 0:
                if face_sel < 0 or f == face_sel:
                    phi = phi_face[c, f]
                    if phi < 0.0:
                        eq.rhs[c] -= phi * value

# Convert the equation builder into CSR storage
# See support.sparse in support/sparse.py for CSR details
def fvm_to_csr(eq: FVMEquation,
               mesh: CartesianMesh) -> CSRMatrix:
    result: CSRMatrix
    max_nnz: int = 0
    nnz: int = 0
    i: int = 0
    f: int = 0
    s: int = 0
    nbr: int = 0
    data: array[float, :]
    indices: array[int, :]
    indptr: array[int, :]

    max_nnz = mesh.cell_capacity * 25
    allocate(data, max_nnz)
    allocate(indices, max_nnz)
    allocate(indptr, mesh.cell_capacity + 1)
    data = 0.0
    indices = 0
    indptr = 0

    for i in range(mesh.cell_capacity):
        indptr[i] = nnz
        if mesh.is_leaf[i]:
            data[nnz] = eq.diag[i]
            indices[nnz] = i
            nnz += 1
            for f in range(6):
                for s in range(4):
                    nbr = mesh.neighbor[i, f, s]
                    if nbr >= 0 and eq.offdiag[i, f, s] != 0.0:
                        data[nnz] = eq.offdiag[i, f, s]
                        indices[nnz] = nbr
                        nnz += 1
        else:
            data[nnz] = 1.0
            indices[nnz] = i
            nnz += 1
    indptr[mesh.cell_capacity] = nnz

    result.data = data
    result.indices = indices
    result.indptr = indptr
    result.num_rows = mesh.cell_capacity
    result.num_cols = mesh.cell_capacity
    return result

# Solve the assembled equation with Conjugate Gradient
# Only valid for SPD systems
# See support.sparse.cg in support/sparse.py for details
def fvm_solve_cg(eq: FVMEquation,
                 mesh: CartesianMesh,
                 field_out: array[float, :],
                 tol: float,
                 max_iter: int):
    A: CSRMatrix
    sol: array[float, :]
    rhs: array[float, :]
    i: int = 0
    l: int = 0
    c: int = 0

    A = fvm_to_csr(eq, mesh)
    allocate(rhs, mesh.cell_capacity)
    rhs = 0.0
    for i in range(mesh.cell_capacity):
        if mesh.is_leaf[i]:
            rhs[i] = eq.rhs[i]
    sol = cg(A, rhs, tol, max_iter)
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        field_out[c] = sol[c]

# Solve the assembled equation with BiCGStab (for nonsymmetric matrices)
# See support.sparse.bicgstab in support/sparse.py for details
def fvm_solve_bicgstab(eq: FVMEquation,
                       mesh: CartesianMesh,
                       field_out: array[float, :],
                       tol: float,
                       max_iter: int):
    A: CSRMatrix
    sol: array[float, :]
    rhs: array[float, :]
    i: int = 0
    l: int = 0
    c: int = 0

    A = fvm_to_csr(eq, mesh)
    allocate(rhs, mesh.cell_capacity)
    rhs = 0.0
    for i in range(mesh.cell_capacity):
        if mesh.is_leaf[i]:
            rhs[i] = eq.rhs[i]
    sol = bicgstab(A, rhs, tol, max_iter)
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        field_out[c] = sol[c]

# Apply a diagonal-only solve for equations without off-diagonal terms.
def fvm_solve_diag(eq: FVMEquation,
                   mesh: CartesianMesh,
                   field_out: array[float, :]):
    c: int = 0
    # See fvc_ddt for is_leaf check info 
    @par
    for c in range(mesh.cell_capacity):
        if mesh.is_leaf[c]:
            if abs(eq.diag[c]) > 0.0:
                field_out[c] = eq.rhs[c] / eq.diag[c]

# ---- BDIM (Boundary Data Immersion Method) helpers ----
# See the "MW" reference at the top of the file

# Sample the exact STL signed distance at every active leaf center, writing into
# sdf_out (cell-id indexed). Build the bin acceleration structure once with
# geom_stl_build_bins and pass it in; this avoids the old intermediate rectilinear
# SDF grid and its trilinear interpolation, so the body is resolved to the STL
# triangle resolution at the mesh's own cell centers. The bins depend only on
# the STL, so the same bins serve every refinement pass.
def fvc_sample_sdf_from_stl(mesh: CartesianMesh,
                            stl: STLMesh,
                            bins: STLBins,
                            sdf_out: array[float, :]):
    l: int = 0
    c: int = 0
    # calls geom_stl_sdf_point per cell, which GCC do concurrent autopar will not thread
    @omp
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        sdf_out[c] = geom_stl_sdf_point(stl, bins,
                                        mesh.center[c, 0],
                                        mesh.center[c, 1],
                                        mesh.center[c, 2])

# Pi constant used by the BDIM cosine kernel.
BDIM_PI: float = 3.14159265358979324

# MW eq. 16a
# BDIM zeroth moment (fluid volume fraction): smooth transition from 0 in solid
# to 1 in fluid over the band [-eps, eps].
def fvc_bdim_mu0(d: float, eps: float) -> float:
    if d <= -eps:
        return 0.0
    if d >= eps:
        return 1.0
    return 0.5 * (1.0 + d / eps + sin(BDIM_PI * d / eps) / BDIM_PI)

# MW eq. 16b
# BDIM first moment (interface thickness kernel): nonzero only in [-eps, eps].
def fvc_bdim_mu1(d: float, eps: float) -> float:
    if d <= -eps:
        return 0.0
    if d >= eps:
        return 0.0
    return eps * (0.25 - (d / (2.0 * eps)) ** 2
                  - (d * sin(BDIM_PI * d / eps)) / (2.0 * BDIM_PI * eps)
                  + (1.0 + cos(BDIM_PI * d / eps)) / (2.0 * BDIM_PI * BDIM_PI))

# Fill BDIM moments and solid mask for every active leaf using sampled SDF values.
def fvc_bdim_weights(mesh: CartesianMesh,
                     sdf_cell: array[float, :],
                     eps: float,
                     mu0_out: array[float, :],
                     mu1_out: array[float, :],
                     solid_mask_out: array[float, :]):
    l: int = 0
    c: int = 0
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        mu0_out[c] = fvc_bdim_mu0(sdf_cell[c], eps)
        mu1_out[c] = fvc_bdim_mu1(sdf_cell[c], eps)
        solid_mask_out[c] = 1.0 - mu0_out[c]

# TODO: Parallelize
# Compute normalized SDF gradient (points solid to fluid since SDF > 0 in fluid).
# Uses central difference where both neighbors exist, one-sided otherwise.
def fvc_sdf_normal(mesh: CartesianMesh,
                   sdf_cell: array[float, :],
                   normal_out: array[float, :, :]):
    l: int = 0
    c: int = 0
    gx: float = 0.0
    gy: float = 0.0
    gz: float = 0.0
    nminus: int = 0
    nplus: int = 0
    inv_dx: float = 0.0
    mag: float = 0.0
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        inv_dx = 1.0 / mesh.dx[c]
        gx = 0.0
        gy = 0.0
        gz = 0.0

        # X
        nminus = mesh.neighbor[c, 0, 0]
        nplus = mesh.neighbor[c, 1, 0]
        if nminus >= 0 and nplus >= 0:
            gx = 0.5 * inv_dx * (sdf_cell[nplus] - sdf_cell[nminus])
        elif nplus >= 0:
            gx = inv_dx * (sdf_cell[nplus] - sdf_cell[c])
        elif nminus >= 0:
            gx = inv_dx * (sdf_cell[c] - sdf_cell[nminus])

        # Y
        nminus = mesh.neighbor[c, 2, 0]
        nplus = mesh.neighbor[c, 3, 0]
        if nminus >= 0 and nplus >= 0:
            gy = 0.5 * inv_dx * (sdf_cell[nplus] - sdf_cell[nminus])
        elif nplus >= 0:
            gy = inv_dx * (sdf_cell[nplus] - sdf_cell[c])
        elif nminus >= 0:
            gy = inv_dx * (sdf_cell[c] - sdf_cell[nminus])

        # Z
        nminus = mesh.neighbor[c, 4, 0]
        nplus = mesh.neighbor[c, 5, 0]
        if nminus >= 0 and nplus >= 0:
            gz = 0.5 * inv_dx * (sdf_cell[nplus] - sdf_cell[nminus])
        elif nplus >= 0:
            gz = inv_dx * (sdf_cell[nplus] - sdf_cell[c])
        elif nminus >= 0:
            gz = inv_dx * (sdf_cell[c] - sdf_cell[nminus])

        mag = sqrt(gx * gx + gy * gy + gz * gz)
        if mag > 0.0:
            normal_out[c, 0] = gx / mag
            normal_out[c, 1] = gy / mag
            normal_out[c, 2] = gz / mag
        else:
            normal_out[c, 0] = 0.0
            normal_out[c, 1] = 0.0
            normal_out[c, 2] = 0.0

# NOTE: Created as a helper for fvc_bdim_apply_static_body below
# Normal derivative of a vector field: dn_out[c, k] = grad(u_k) dot normal[c].
# Central differences where both neighbors exist, one-sided at boundaries.
def fvc_normal_derivative_vector(mesh: CartesianMesh,
                                 vector_field: array[float, :, :],
                                 normal: array[float, :, :],
                                 dn_out: array[float, :, :]):
    l: int = 0
    c: int = 0
    k: int = 0
    nminus: int = 0
    nplus: int = 0
    inv_dx: float = 0.0
    du_dx: float = 0.0
    du_dy: float = 0.0
    du_dz: float = 0.0
    # See OpenMP note in fvc_interpolate 
    @omp
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        inv_dx = 1.0 / mesh.dx[c]
        for k in range(3):
            du_dx = 0.0
            du_dy = 0.0
            du_dz = 0.0

            # X
            nminus = mesh.neighbor[c, 0, 0]
            nplus = mesh.neighbor[c, 1, 0]
            if nminus >= 0 and nplus >= 0:
                du_dx = 0.5 * inv_dx * (vector_field[nplus, k] - vector_field[nminus, k])
            elif nplus >= 0:
                du_dx = inv_dx * (vector_field[nplus, k] - vector_field[c, k])
            elif nminus >= 0:
                du_dx = inv_dx * (vector_field[c, k] - vector_field[nminus, k])

            # Y
            nminus = mesh.neighbor[c, 2, 0]
            nplus = mesh.neighbor[c, 3, 0]
            if nminus >= 0 and nplus >= 0:
                du_dy = 0.5 * inv_dx * (vector_field[nplus, k] - vector_field[nminus, k])
            elif nplus >= 0:
                du_dy = inv_dx * (vector_field[nplus, k] - vector_field[c, k])
            elif nminus >= 0:
                du_dy = inv_dx * (vector_field[c, k] - vector_field[nminus, k])

            # Z
            nminus = mesh.neighbor[c, 4, 0]
            nplus = mesh.neighbor[c, 5, 0]
            if nminus >= 0 and nplus >= 0:
                du_dz = 0.5 * inv_dx * (vector_field[nplus, k] - vector_field[nminus, k])
            elif nplus >= 0:
                du_dz = inv_dx * (vector_field[nplus, k] - vector_field[c, k])
            elif nminus >= 0:
                du_dz = inv_dx * (vector_field[c, k] - vector_field[nminus, k])

            dn_out[c, k] = du_dx * normal[c, 0] + du_dy * normal[c, 1] + du_dz * normal[c, 2]

# MW eq. 17
# Static no-slip BDIM velocity blend (prescribed body velocity V = 0).
# u_out = mu0 * u_fluid - mu1 * (grad(u_fluid) dot normal).
# Safe to call with u_out aliasing u_fluid: dn_u is computed before the write loop.
def fvc_bdim_apply_static_body(mesh: CartesianMesh,
                                u_fluid: array[float, :, :],
                                normal: array[float, :, :],
                                mu0: array[float, :],
                                mu1: array[float, :],
                                u_out: array[float, :, :]):
    dn_u: array[float, :, :]
    c: int = 0
    k: int = 0
    allocate(dn_u, mesh.cell_capacity, 3)
    fvc_normal_derivative_vector(mesh, u_fluid, normal, dn_u)

    # See fvc_ddt for is_leaf check info
    @par
    for c in range(mesh.cell_capacity):
        if mesh.is_leaf[c]:
            for k in range(3):
                u_out[c, k] = mu0[c] * u_fluid[c, k] + mu1[c] * dn_u[c, k] # NOTE: There used to be a '-' in front of mu1 here

# Dimensionless wall distance (yPlus) at the BDIM transition band.
# yPlus = |u_tangential| * |d| / nu  for  0 < mu0 < 1 (transition band cells).
# yPlus = 0 for solid (mu0 <= 0) and deep-fluid (mu0 >= 1) cells.
# sdf_cell: per-cell signed distance field (passed separately since sdf is on the
#           FieldSet struct, not on the base CartesianMesh).
def fvc_yPlus(mesh: CartesianMesh,
              velocity: array[float, :, :],
              normal: array[float, :, :],
              sdf_cell: array[float, :],
              mu0: array[float, :],
              nu: float,
              yPlus_out: array[float, :]):
    c: int = 0
    k: int = 0
    u_dot_n: float = 0.0
    u_tan_x: float = 0.0
    u_tan_y: float = 0.0
    u_tan_z: float = 0.0
    u_tan_mag: float = 0.0
    d: float = 0.0
    # See fvc_ddt for is_leaf check info
    @par
    for c in range(mesh.cell_capacity):
        if mesh.is_leaf[c]:
            if mu0[c] > 0.0 and mu0[c] < 1.0:
                # Tangential velocity = u - (u . n) * n
                u_dot_n = (velocity[c, 0] * normal[c, 0]
                         + velocity[c, 1] * normal[c, 1]
                         + velocity[c, 2] * normal[c, 2])
                u_tan_x = velocity[c, 0] - u_dot_n * normal[c, 0]
                u_tan_y = velocity[c, 1] - u_dot_n * normal[c, 1]
                u_tan_z = velocity[c, 2] - u_dot_n * normal[c, 2]
                u_tan_mag = sqrt(u_tan_x * u_tan_x
                               + u_tan_y * u_tan_y
                               + u_tan_z * u_tan_z)
                d = abs(sdf_cell[c])
                if d > 0.0 and nu > 0.0:
                    yPlus_out[c] = u_tan_mag * d / nu
                else:
                    yPlus_out[c] = 0.0
            else:
                yPlus_out[c] = 0.0

# Velocity magnitude for diagnostics and export.
def fvc_vector_mag(mesh: CartesianMesh,
                   vector_field: array[float, :, :],
                   mag_out: array[float, :]):
    c: int = 0
    # See fvc_ddt for is_leaf check info
    @par
    for c in range(mesh.cell_capacity):
        if mesh.is_leaf[c]:
            mag_out[c] = sqrt(
                vector_field[c, 0] ** 2
                + vector_field[c, 1] ** 2
                + vector_field[c, 2] ** 2)

# ---- Face flux and vector interpolation ----

# Face flux from cell-centered velocity using the outward convention:
# phi[c, f] = u_face dot n_f * area_f, positive means outward from cell c.
# Even faces (0, 2, 4) have inward-pointing positive velocity, so they carry
# a negative sign; odd faces (1, 3, 5) carry a positive sign.
def fvc_flux_from_velocity(mesh: CartesianMesh,
                            velocity: array[float, :, :],
                            phi_face_out: array[float, :, :]):
    l: int = 0
    c: int = 0
    f: int = 0
    s: int = 0
    nbr: int = 0
    comp: int = 0
    u_face: float = 0.0
    sign_f: float = 0.0
    slot_area: float = 0.0
    phi_sum: float = 0.0
    
    # TODO replace with @par eventually
    @omp
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        for f in range(6):
            if f == 0 or f == 1:
                comp = 0
            elif f == 2 or f == 3:
                comp = 1
            else:
                comp = 2
            if f == 0 or f == 2 or f == 4:
                sign_f = -1.0
            else:
                sign_f = 1.0
            phi_sum = 0.0
            for s in range(4):
                slot_area = fvc_face_slot_area(mesh, c, f, s)
                if slot_area > 0.0:
                    nbr = mesh.neighbor[c, f, s]
                    if nbr >= 0:
                        u_face = 0.5 * (velocity[c, comp] + velocity[nbr, comp])
                    else:
                        u_face = velocity[c, comp]
                    phi_sum += sign_f * u_face * slot_area
            phi_face_out[c, f] = phi_sum

# Face-interpolate a cell-centered vector field to (cell, face, component) storage.
def fvc_interpolate_vector(mesh: CartesianMesh,
                            vector_field: array[float, :, :],
                            face_vector_out: array[float, :, :, :]):
    l: int = 0
    c: int = 0
    f: int = 0
    k: int = 0
    nbr: int = 0

    # TODO replace with @par eventually
    @omp
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        for f in range(6):
            nbr = mesh.neighbor[c, f, 0]
            for k in range(3):
                if nbr >= 0:
                    face_vector_out[c, f, k] = 0.5 * (vector_field[c, k] + vector_field[nbr, k])
                else:
                    face_vector_out[c, f, k] = vector_field[c, k]

# Cell-centered gradient of one component of a vector field.
def fvc_grad_component(mesh: CartesianMesh,
                        vector_field: array[float, :, :],
                        component: int,
                        grad_out: array[float, :, :]):
    l: int = 0
    c: int = 0
    nbr: int = 0
    vm: float = 0.0
    vp: float = 0.0
    inv2dx: float = 0.0

    # TODO replace with @par eventually
    @omp
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        inv2dx = 1.0 / (2.0 * mesh.dx[c])

        # X
        vm = vector_field[c, component] # minus
        vp = vector_field[c, component] # plus
        nbr = mesh.neighbor[c, 0, 0]
        if nbr >= 0:
            vm = vector_field[nbr, component]
        nbr = mesh.neighbor[c, 1, 0]
        if nbr >= 0:
            vp = vector_field[nbr, component]
        grad_out[c, 0] = (vp - vm) * inv2dx

        # Y
        vm = vector_field[c, component]
        vp = vector_field[c, component]
        nbr = mesh.neighbor[c, 2, 0]
        if nbr >= 0:
            vm = vector_field[nbr, component]
        nbr = mesh.neighbor[c, 3, 0]
        if nbr >= 0:
            vp = vector_field[nbr, component]
        grad_out[c, 1] = (vp - vm) * inv2dx

        # Z
        vm = vector_field[c, component]
        vp = vector_field[c, component]
        nbr = mesh.neighbor[c, 4, 0]
        if nbr >= 0:
            vm = vector_field[nbr, component]
        nbr = mesh.neighbor[c, 5, 0]
        if nbr >= 0:
            vp = vector_field[nbr, component]
        grad_out[c, 2] = (vp - vm) * inv2dx

# Cell-centered curl of a vector field.
def fvc_vorticity(mesh: CartesianMesh,
                  velocity: array[float, :, :],
                  vort_out: array[float, :, :]):
    l: int = 0
    c: int = 0
    nbr: int = 0
    inv2dx: float = 0.0
    du_dy: float = 0.0
    du_dz: float = 0.0
    dv_dx: float = 0.0
    dv_dz: float = 0.0
    dw_dx: float = 0.0
    dw_dy: float = 0.0

    # TODO replace with @par eventually
    @omp
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        inv2dx = 1.0 / (2.0 * mesh.dx[c])

        # X derivatives use face 0 and face 1 neighbors.
        nbr = mesh.neighbor[c, 0, 0]
        if nbr >= 0:
            dv_dx = -velocity[nbr, 1]
            dw_dx = -velocity[nbr, 2]
        else:
            dv_dx = -velocity[c, 1]
            dw_dx = -velocity[c, 2]
        nbr = mesh.neighbor[c, 1, 0]
        if nbr >= 0:
            dv_dx += velocity[nbr, 1]
            dw_dx += velocity[nbr, 2]
        else:
            dv_dx += velocity[c, 1]
            dw_dx += velocity[c, 2]
        dv_dx = dv_dx * inv2dx
        dw_dx = dw_dx * inv2dx

        # Y derivatives use face 2 and face 3 neighbors.
        nbr = mesh.neighbor[c, 2, 0]
        if nbr >= 0:
            du_dy = -velocity[nbr, 0]
            dw_dy = -velocity[nbr, 2]
        else:
            du_dy = -velocity[c, 0]
            dw_dy = -velocity[c, 2]
        nbr = mesh.neighbor[c, 3, 0]
        if nbr >= 0:
            du_dy += velocity[nbr, 0]
            dw_dy += velocity[nbr, 2]
        else:
            du_dy += velocity[c, 0]
            dw_dy += velocity[c, 2]
        du_dy = du_dy * inv2dx
        dw_dy = dw_dy * inv2dx

        # Z derivatives use face 4 and face 5 neighbors.
        nbr = mesh.neighbor[c, 4, 0]
        if nbr >= 0:
            du_dz = -velocity[nbr, 0]
            dv_dz = -velocity[nbr, 1]
        else:
            du_dz = -velocity[c, 0]
            dv_dz = -velocity[c, 1]
        nbr = mesh.neighbor[c, 5, 0]
        if nbr >= 0:
            du_dz += velocity[nbr, 0]
            dv_dz += velocity[nbr, 1]
        else:
            du_dz += velocity[c, 0]
            dv_dz += velocity[c, 1]
        du_dz = du_dz * inv2dx
        dv_dz = dv_dz * inv2dx

        vort_out[c, 0] = dw_dy - dv_dz
        vort_out[c, 1] = du_dz - dw_dx
        vort_out[c, 2] = dv_dx - du_dy

# ---- Momentum assembly and relaxation ----

# Matches the momentum component "UEqn" in the icoFoam PISO loop: https://cpp.openfoam.org/v4/icoFoam_8C_source.html
# Ties back to the PISO loop inside the PIMPLE algorithm https://doc.cfd.direct/notes/cfd-general-principles/the-pimple-algorithm
# Assemble transient, upwind convection, and diffusion for one velocity component
# Very cool! This is where we finally get to mimic the high-level openfoam equation construction API
# Related (though not quite the same): https://github.com/OpenFOAM/OpenFOAM-13/blob/19a3d5400c8c936e24745f5cbfce8906084d2621/applications/modules/incompressibleFluid/momentumPredictor.C#L36
# Also see Jasak 1996 thesis, Section 3.3: Discretisation of the Transport Equation 
#   - https://www.researchgate.net/profile/Hrvoje-Jasak/publication/230605842_Error_Analysis_and_Estimation_for_the_Finite_Volume_Method_With_Applications_to_Fluid_Flows/links/558958d908ae2affe714ae30/Error-Analysis-and-Estimation-for-the-Finite-Volume-Method-With-Applications-to-Fluid-Flows.pdf
def fvm_momentum_component(eq: FVMEquation,
                            mesh: CartesianMesh,
                            u_old_comp: array[float, :],
                            phi_face: array[float, :, :],
                            nu_face: array[float, :, :],
                            dt: float):
    fvm_ddt(eq, mesh, u_old_comp, dt)
    fvm_div(eq, mesh, phi_face)
    fvm_laplacian(eq, mesh, nu_face)

# Implicit body penalty driving solid and transition cells toward body velocity.
# For a static no-slip body body_value = 0.0 so only the diagonal is augmented.
# NOTE: This is a bit of a guess at the moment since BDIM was formulated for FDM, so we're bringing volume into play
def fvm_bdim_static_body_penalty(eq: FVMEquation,
                                  mesh: CartesianMesh,
                                  mu0: array[float, :],
                                  penalty: float,
                                  body_value: float):
    c: int = 0
    coeff: float = 0.0
    # TODO switch to @par eventually
    @omp
    for c in range(mesh.cell_capacity):
        if mesh.is_leaf[c]:
            coeff = penalty * (1.0 - mu0[c]) * mesh.volume[c]
            eq.diag[c] += coeff
            eq.rhs[c] += coeff * body_value

# Matrix under-relaxation of an assembled scalar equation
# See https://doc.cfd.direct/notes/cfd-general-principles/under-relaxation ; eq. 5.15
# Scales the diagonal by 1/alpha and adds the implicit correction to the RHS
# NOTE: Assumes that eq.diag has already been built (ddt + convection + diffusion + Dirichlet + BDIM penalty + ...)
def fvm_under_relax(eq: FVMEquation,
                    mesh: CartesianMesh,
                    field_old: array[float, :],
                    alpha: float):
    c: int = 0
    d: float = 0.0
    # TODO switch to @par eventually
    @omp
    for c in range(mesh.cell_capacity):
        if mesh.is_leaf[c]:
            d = eq.diag[c]
            eq.diag[c] = d / alpha
            eq.rhs[c] += (1.0/alpha - 1.0) * d * field_old[c]

# Explicit scalar blending
def fvc_under_relax_scalar(mesh: CartesianMesh,
                            old_field: array[float, :],
                            new_field: array[float, :],
                            alpha: float):
    c: int = 0
    # See fvc_ddt for is_leaf check info
    @par
    for c in range(mesh.cell_capacity):
        if mesh.is_leaf[c]:
            new_field[c] = alpha * new_field[c] + (1.0 - alpha) * old_field[c]

# Explicit vector field blending
def fvc_under_relax_vector(mesh: CartesianMesh,
                            old_field: array[float, :, :],
                            new_field: array[float, :, :],
                            alpha: float):
    c: int = 0
    k: int = 0
    # See fvc_ddt for is_leaf check info
    @par
    for c in range(mesh.cell_capacity):
        if mesh.is_leaf[c]:
            for k in range(3):
                new_field[c, k] = alpha * new_field[c, k] + (1.0 - alpha) * old_field[c, k]

# ---- Pressure-velocity coupling helpers ----
# NOTE: For functions below, reference https://doc.cfd.direct/notes/cfd-general-principles/pressure-velocity-coupling
#   Specifically the momentum corrector H(u)/A or "HbyA"

# Compute 1/A from the momentum equation diagonal; returns 0 for zero diagonal.
def fvc_inverse_diag(mesh: CartesianMesh,
                      eq: FVMEquation,
                      inv_diag_out: array[float, :]):
    c: int = 0
    # See fvc_ddt for is_leaf check info
    @par
    for c in range(mesh.cell_capacity):
        if mesh.is_leaf[c]:
            if abs(eq.diag[c]) > 1.0e-7:
                inv_diag_out[c] = 1.0 / eq.diag[c]
            else:
                inv_diag_out[c] = 0.0

# Rhie-Chow inspired momentum correction helper
# See "Rhie-Chow interpolation in OpenFOAM" https://www.tfd.chalmers.se/~hani/kurser/OS_CFD_2007/rhiechow.pdf by Karrholm
#   "This method gives an oscillation-free velocity in line with Rhie-Chow, even though there is no explicit Rhie-Chow correction."
#   Four points:
#   1. "phi does not include any effect of pressure when solving the continuity equation"
#       In examples/support_geom_cartesian_fvm_body_pimple.py the RHS is -div(phiHbyA)
#   2. "rUA does not include any effect of pressure"
#       invA from fvc_inverse_diag
#   3. "The Laplacian-term of p uses the gradient of p on the cell face, calculated using neighbouring cells, not neighbouring faces"
#       fvm_pressure_laplacian_invA matches to eq. 16 in Karrholm 
#   4. "The gradient-term of p [the velocity corrector] is calculated from the cell-face values of p."
#       See eq. 17 in Karrholm and fvc_momentum_pressure_correct
# Compute HbyA = H(u) / A for one velocity component.
# H(u)[c] = rhs[c] - sum_nb(offdiag[c,f,s] * field[nb]).
# OpenFOAM src (not the same approach, but useful to look at): 
#   https://github.com/OpenFOAM/OpenFOAM-13/blob/master/applications/modules/incompressibleFluid/correctPressure.C
#   https://github.com/OpenFOAM/OpenFOAM-13/blob/master/src/finiteVolume/cfdTools/general/constrainHbyA/constrainHbyA.C
def fvc_HbyA_component(mesh: CartesianMesh,
                        eq: FVMEquation,
                        field: array[float, :],
                        invA: array[float, :],
                        hbyA_out: array[float, :]):
    l: int = 0
    c: int = 0
    f: int = 0
    s: int = 0
    nbr: int = 0
    h: float = 0.0
    # TODO switch to @par eventually
    @omp
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        h = eq.rhs[c]
        for f in range(6):
            for s in range(4):
                nbr = mesh.neighbor[c, f, s]
                if nbr >= 0 and (s == 0 or nbr != mesh.neighbor[c, f, 0]):
                    h -= eq.offdiag[c, f, s] * field[nbr]
        hbyA_out[c] = h * invA[c]

# See comments for fvc_HbyA_component
# Face flux from HbyA using the same outward convention as fvc_flux_from_velocity.
def fvc_flux_from_hbyA(mesh: CartesianMesh,
                        hbyA: array[float, :, :],
                        phiHbyA_out: array[float, :, :]):
    fvc_flux_from_velocity(mesh, hbyA, phiHbyA_out)

# See comments for fvc_HbyA_component
# Pressure Laplacian: div(invA_face * grad(p)). Wraps fvm_laplacian.
def fvm_pressure_laplacian(eq: FVMEquation,
                            mesh: CartesianMesh,
                            invA_face: array[float, :, :]):
    fvm_laplacian(eq, mesh, invA_face)

# Pressure Laplacian using cell invA values per face-neighbor slot.
# Cell-invA variant of fvm_pressure_laplacian: the face diffusion coefficient is
# the slot average 0.5*(invA[c]+invA[nbr]) instead of a prestored face field.
# Assembles div(invA grad(p)) with the compact two-point stencil, same form as
# fvm_laplacian. The slot average must stay in sync with the flux correctors
# fvc_pressure_flux_correction_dirichlet_invA so the corrected flux matches this matrix.
# See comments for fvc_HbyA_component (Karrholm point 3, eq. 16).
# OpenFOAM assembles the implicit Laplacian in gaussLaplacianScheme:
#   https://github.com/OpenFOAM/OpenFOAM-13/blob/master/src/finiteVolume/finiteVolume/laplacianSchemes/gaussLaplacianScheme/gaussLaplacianScheme.C
def fvm_pressure_laplacian_invA(eq: FVMEquation,
                                mesh: CartesianMesh,
                                invA: array[float, :]):
    l: int = 0
    c: int = 0
    f: int = 0
    s: int = 0
    nbr: int = 0
    coeff: float = 0.0
    gamma: float = 0.0
    dcenters: float = 0.0
    slot_area: float = 0.0
    # Use slot-local interpolation so coarse-to-fine pressure rows match
    # TODO switch to @par eventually
    @omp
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        for f in range(6):
            for s in range(4):
                nbr = mesh.neighbor[c, f, s]
                slot_area = fvc_face_slot_area(mesh, c, f, s)
                if nbr >= 0 and slot_area > 0.0:
                    dcenters = 0.5 * (mesh.dx[c] + mesh.dx[nbr])
                    gamma = 0.5 * (invA[c] + invA[nbr])
                    coeff = gamma * slot_area / dcenters
                    eq.diag[c] += coeff
                    eq.offdiag[c, f, s] -= coeff

# See comments for fvc_HbyA_component
# Apply pressure Dirichlet using cell invA at selected boundary faces
# Example call: fvm_pressure_dirichlet_invA(p_eq, mesh, invA, 0, 0.0)
# Dirichlet BC (fixed value): https://doc.cfd.direct/notes/cfd-general-principles/fixed-value-and-fixed-gradient
# OpenFOAM: https://github.com/OpenFOAM/OpenFOAM-13/blob/19a3d5400c8c936e24745f5cbfce8906084d2621/src/finiteVolume/finiteVolume/laplacianSchemes/gaussLaplacianScheme/gaussLaplacianScheme.C#L46
#   A fixed-value patch gets applied to the implicit Laplacian in the OpenFOAM ref above; maps to the "value" input to this function
def fvm_pressure_dirichlet_invA(eq: FVMEquation,
                                mesh: CartesianMesh,
                                invA: array[float, :],
                                face_sel: int,
                                value: float):
    l: int = 0
    c: int = 0
    f: int = 0
    coeff: float = 0.0
    half_dx: float = 0.0
    # Boundary pressure lies a half cell from the cell center
    # TODO switch to @par eventually
    @omp
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        for f in range(6):
            if mesh.neighbor[c, f, 0] < 0:
                if face_sel < 0 or f == face_sel:
                    half_dx = 0.5 * mesh.dx[c] # openfoam deltaCoeffs
                    coeff = invA[c] * mesh.face_area[c, f] / half_dx
                    eq.diag[c] += coeff
                    eq.rhs[c] += coeff * value

# TODO remove?
# See comments for fvc_HbyA_component
# Correct face flux: phi = phiHbyA - invA_face * area * (dp outward / d_centers).
# For both face 0 and face 1, the outward pressure gradient equals
# (p[nbr] - p[c]) / d_centers (same sign for all six cartesian faces).
# Boundary faces carry zero correction (homogeneous Neumann on pressure).
# def fvc_pressure_flux_correction(mesh: CartesianMesh,
#                                   pressure: array[float, :],
#                                   invA_face: array[float, :, :],
#                                   phiHbyA: array[float, :, :],
#                                   phi_out: array[float, :, :]):
#     l: int = 0
#     c: int = 0
#     f: int = 0
#     s: int = 0
#     nbr: int = 0
#     dp: float = 0.0
#     dcenters: float = 0.0
#     slot_area: float = 0.0
#     phi_corr: float = 0.0
#     # TODO switch to @par eventually
#     @omp
#     for l in range(mesh.num_leaves):
#         c = mesh.leaf_ids[l]
#         for f in range(6):
#             phi_corr = phiHbyA[c, f]
#             for s in range(4):
#                 nbr = mesh.neighbor[c, f, s]
#                 slot_area = fvc_face_slot_area(mesh, c, f, s)
#                 if nbr >= 0 and slot_area > 0.0:
#                     dcenters = 0.5 * (mesh.dx[c] + mesh.dx[nbr])
#                     dp = (pressure[nbr] - pressure[c]) / dcenters
#                     phi_corr -= invA_face[c, f] * slot_area * dp
#             phi_out[c, f] = phi_corr

# TODO: remove?
# See comments for fvc_HbyA_component
# Correct face flux and include a matching pressure Dirichlet boundary term.
# def fvc_pressure_flux_correction_dirichlet(mesh: CartesianMesh,
#                                            pressure: array[float, :],
#                                            invA_face: array[float, :, :],
#                                            phiHbyA: array[float, :, :],
#                                            face_sel: int,
#                                            value: float,
#                                            phi_out: array[float, :, :]):
#     l: int = 0
#     c: int = 0
#     f: int = 0
#     s: int = 0
#     nbr: int = 0
#     dp: float = 0.0
#     dcenters: float = 0.0
#     half_dx: float = 0.0
#     slot_area: float = 0.0
#     phi_corr: float = 0.0
#     # TODO switch to @par eventually
#     @omp
#     for l in range(mesh.num_leaves):
#         c = mesh.leaf_ids[l]
#         for f in range(6):
#             phi_corr = phiHbyA[c, f]
#             for s in range(4):
#                 nbr = mesh.neighbor[c, f, s]
#                 slot_area = fvc_face_slot_area(mesh, c, f, s)
#                 if nbr >= 0 and slot_area > 0.0:
#                     dcenters = 0.5 * (mesh.dx[c] + mesh.dx[nbr])
#                     dp = (pressure[nbr] - pressure[c]) / dcenters
#                     phi_corr -= invA_face[c, f] * slot_area * dp
#             if mesh.neighbor[c, f, 0] < 0:
#                 if face_sel < 0 or f == face_sel:
#                     half_dx = 0.5 * mesh.dx[c]
#                     phi_corr += invA_face[c, f] * mesh.face_area[c, f] * (pressure[c] - value) / half_dx
#             phi_out[c, f] = phi_corr

# See comments for fvc_HbyA_component
# Correct face flux using cell invA values per face-neighbor slot
# Example call: fvc_pressure_flux_correction_dirichlet_invA(mesh, mesh.p, invA, phiHbyA, 0, 0.0, phiHbyA)
# Some notes:
#   The interior gamma = 0.5*(invA[c]+invA[nbr]) must match fvm_pressure_laplacian_invA
#   The boundary invA[c]*area/half_dx must match fvm_pressure_dirichlet_invA
#   The boundary sign uses (p[c] - value), the outward gradient, consistent with the diagonal sign added in fvm_pressure_dirichlet_invA
def fvc_pressure_flux_correction_dirichlet_invA(mesh: CartesianMesh,
                                                pressure: array[float, :],
                                                invA: array[float, :],
                                                phiHbyA: array[float, :, :],
                                                face_sel: int,
                                                value: float,
                                                phi_out: array[float, :, :]):
    l: int = 0
    c: int = 0
    f: int = 0
    s: int = 0
    nbr: int = 0
    dp: float = 0.0
    gamma: float = 0.0
    dcenters: float = 0.0
    half_dx: float = 0.0
    slot_area: float = 0.0
    phi_corr: float = 0.0
    # Use the same slot coefficients as fvm_pressure_laplacian_invA
    # TODO switch to @par eventually
    @omp
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        for f in range(6):
            phi_corr = phiHbyA[c, f]
            for s in range(4):
                nbr = mesh.neighbor[c, f, s]
                slot_area = fvc_face_slot_area(mesh, c, f, s)
                if nbr >= 0 and slot_area > 0.0:
                    dcenters = 0.5 * (mesh.dx[c] + mesh.dx[nbr])
                    gamma = 0.5 * (invA[c] + invA[nbr])
                    dp = (pressure[nbr] - pressure[c]) / dcenters
                    phi_corr -= gamma * slot_area * dp
            if mesh.neighbor[c, f, 0] < 0:
                if face_sel < 0 or f == face_sel:
                    half_dx = 0.5 * mesh.dx[c]
                    phi_corr += invA[c] * mesh.face_area[c, f] * (pressure[c] - value) / half_dx
            phi_out[c, f] = phi_corr

# NOTE: See comments for fvc_HbyA_component
# Velocity correction from pressure gradient: u = HbyA - invA * grad(p)
def fvc_momentum_pressure_correct(mesh: CartesianMesh,
                                   hbyA: array[float, :, :],
                                   invA: array[float, :],
                                   pressure: array[float, :],
                                   velocity_out: array[float, :, :]):
    grad_p: array[float, :, :]
    c: int = 0
    k: int = 0
    allocate(grad_p, mesh.cell_capacity, 3)
    fvc_grad(mesh, pressure, grad_p)
    # See fvc_ddt for is_leaf check info
    @par
    for c in range(mesh.cell_capacity):
        if mesh.is_leaf[c]:
            for k in range(3):
                velocity_out[c, k] = hbyA[c, k] - invA[c] * grad_p[c, k]

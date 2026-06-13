# Transient incompressible flow past a static immersed body with the Finite Volume Method (FVM)
# Implements PIMPLE: https://doc.cfd.direct/notes/cfd-general-principles/the-pimple-algorithm
# NOTE: See support/geom_cartesian_fvm.py for extensive FVM support library references in the comments
#
# Reads a binary STL file, computes a signed distance field, builds an
# adaptively refined CartesianMesh, and runs a simplified PIMPLE
# time-stepping loop with an immersion method used for the static body.
#
# The solver uses:
#   - One momentum predictor solve per velocity component per time step.
#   - Immersed body velocity blend applied after each predictor.
#   - Pressure Poisson equation solved via CG.
#   - One pressure correction per time step.
#
# Scope: static body, no turbulence, no force integration.
# Goal is proof-of-concept for showcasing FortScript FVM capabilities.
#
# Run: ./out/support_geom_cartesian_fvm_body_pimple
# Then open body_pimple.xdmf in ParaView.

import support.geom_stl
import support.geom_cartesian
import support.geom_cartesian_fvm

struct FlowField:
    p: float
    u: array[float, 3]
    sdf: float
    mu0: float
    mu1: float
    solid: float

def main():
    body: STLMesh
    mesh: CartesianMesh[FlowField]

    # Solver parameters.
    n_steps: int = 500
    n_corr: int = 1
    max_courant: float = 0.5
    dt: float = 0.0
    nu: float = 0.01
    alpha_u: float = 0.7
    penalty: float = 1.0e4
    u_inlet_x: float = -1.0
    mom_tol: float = 1.0e-6
    mom_max_iter: int = 200
    p_tol: float = 1.0e-6
    p_max_iter: int = 500

    # Mesh and SDF parameters.
    nx_cells: int = 200
    ny_cells: int = 100
    nz_cells: int = 100
    dx_root: float = 0.0
    dy_root: float = 0.0
    dz_root: float = 0.0
    coarse_dx: float = 0.0
    max_level: int = 2
    refine_tol: float = 8.0
    nbin: int = 16

    # Domain and geometry.
    dom_min: array[float, 3]
    dom_max: array[float, 3]
    x_min: float = -200.0
    x_max: float = 200.0
    y_min: float = -100.0
    y_max: float = 100.0
    z_min: float = -100.0
    z_max: float = 100.0
    spacing_tol: float = 1.0e-10
    eps: float = 0.0

    # STL distance acceleration structure, built once and reused for every
    # direct SDF sample (no intermediate rectilinear grid).
    bins: STLBins

    # Working arrays.
    phi: array[float, :, :]
    phiHbyA: array[float, :, :]
    nu_face: array[float, :, :]
    invA: array[float, :]
    hbyA: array[float, :, :]
    hbyA_comp: array[float, :]
    normal: array[float, :, :]
    u_old: array[float, :, :]
    omega: array[float, :, :]
    u_comp: array[float, :]
    u_mag: array[float, :]
    omega_mag: array[float, :]
    div_phiHbyA: array[float, :]
    div_diag:  array[float, :]
    yPlus:     array[float, :]

    # Equation builders.
    mom_eq: FVMEquation
    p_eq: FVMEquation

    # XDMF export buffers.
    points: array[float, :, :]
    connectivity: array[int, :, :]
    leaf_p: array[float, :]
    leaf_u_x: array[float, :]
    leaf_u_y: array[float, :]
    leaf_u_z: array[float, :]
    leaf_umag: array[float, :]
    leaf_omega_x: array[float, :]
    leaf_omega_y: array[float, :]
    leaf_omega_z: array[float, :]
    leaf_omega_mag: array[float, :]
    leaf_sdf: array[float, :]
    leaf_mu0: array[float, :]
    leaf_mu1: array[float, :]
    leaf_solid:    array[float, :]
    leaf_yPlus:    array[float, :]
    xdmf_xml: string

    # Loop variables.
    step: int = 0
    corr: int = 0
    l: int = 0
    c: int = 0
    k: int = 0
    yp: float = 0.0
    lev: int = 0
    ref_dx: float = 0.0
    u_mag_max: float = 0.0
    min_dt_speed: float = 1.0e-12
    sdf_min: float = 0.0
    sdf_max: float = 0.0
    mu0_min: float = 0.0
    mu0_max: float = 0.0
    mu0_at_sdf_min: float = 0.0
    solid_count: int = 0
    fluid_count: int = 0
    u_pred_max: float = 0.0
    u_corr_max: float = 0.0
    div_phi_max: float = 0.0
    div_u_max: float = 0.0
    viscous_cells: int = 0
    buffer_cells: int = 0
    loglayer_cells: int = 0
    yPlus_min: float = 0.0
    yPlus_max: float = 0.0
    yPlus_sum: float = 0.0
    yPlus_near_body_count: int = 0

    ### ------------------------------------------------------------------------ ###
    ### ----- Set the domain and derive root-cell spacing from cell counts ----- ###
    ### ------------------------------------------------------------------------ ###

    # CartesianMesh root cells are cubic, so counts give the same spacing.
    dom_min[0] = x_min
    dom_min[1] = y_min
    dom_min[2] = z_min
    dom_max[0] = x_max
    dom_max[1] = y_max
    dom_max[2] = z_max
    dx_root = (x_max - x_min) / nx_cells
    dy_root = (y_max - y_min) / ny_cells
    dz_root = (z_max - z_min) / nz_cells
    # Exit early if the requested root grid cannot use cubic cells.
    if abs(dx_root - dy_root) > spacing_tol:
        print("Error: root cell spacing mismatch in x/y:", dx_root, dy_root)
        exit(1)
    if abs(dx_root - dz_root) > spacing_tol:
        print("Error: root cell spacing mismatch in x/z:", dx_root, dz_root)
        exit(1)
    coarse_dx = dx_root
    print("Root spacing dx/dy/dz:", dx_root, dy_root, dz_root)

    ### ------------------------------------------------------- ###
    ### ----- Read centered STL body in meter coordinates ----- ###
    ### ------------------------------------------------------- ###

    geom_stl_read_binary("media/jet/jet_centered.stl", body)
    geom_stl_compute_bounds(body)
    print("STL bounds min:", body.min_bound[0], body.min_bound[1], body.min_bound[2])
    print("STL bounds max:", body.max_bound[0], body.max_bound[1], body.max_bound[2])

    ### ---------------------------------------------------- ###
    ### ----- Build the STL distance acceleration tree ----- ###
    ### ---------------------------------------------------- ###

    # The bins depend only on the STL, so build once and reuse for every direct
    # SDF sample at the (refining) leaf centers. No intermediate grid.
    nbin = geom_stl_sdf_nbin(body.num_triangles)
    print("Building STL bins...")
    geom_stl_build_bins(body, nbin, bins)
    print("Bins done.")

    ### -------------------------------------------------------------------- ###
    ### ----- Build uniform root mesh and refine near the body surface ----- ###
    ### -------------------------------------------------------------------- ###

    geom_cartesian_uniform(mesh, dom_min, dom_max, coarse_dx)
    print("Coarse mesh leaves:", mesh.num_leaves)
    fvc_sample_sdf_from_stl(mesh, body, bins, mesh.sdf)
    print("Done with initial sample")
    
    # Refine the band level-by-level using the batched castellation helper.
    # Each pass samples the exact STL distance at the current leaf centers, then
    # geom_cartesian_refine_band marks every band leaf below the target level,
    # propagates 2:1 balance, splits the whole batch, and rebuilds the neighbor
    # table once. Passing lev + 1 lifts the band by a single level per pass so
    # the band tightens against the geometry as the mesh refines.
    for lev in range(max_level):
        print("Starting refinement level ", lev, " of ", max_level)
        fvc_sample_sdf_from_stl(mesh, body, bins, mesh.sdf)
        geom_cartesian_refine_band(mesh, mesh.sdf, refine_tol, lev + 1)
    print("Refined mesh leaves:", mesh.num_leaves)

    # Sample the exact SDF at the final leaf centers.
    fvc_sample_sdf_from_stl(mesh, body, bins, mesh.sdf)

    ### -------------------------------------------------------------- ###
    ### ----- Compute BDIM-style weights and SDF surface normals ----- ###
    ### -------------------------------------------------------------- ###

    # finest_dx = coarse_dx / 2^max_level (computed without integer power).
    # eps is chosen as 1.5 finest cell widths.
    ref_dx = coarse_dx
    lev = 0
    for lev in range(max_level):
        ref_dx = ref_dx * 0.5
    eps = 1.5 * ref_dx
    allocate(normal, mesh.cell_capacity, 3)
    fvc_sdf_normal(mesh, mesh.sdf, normal)
    fvc_bdim_weights(mesh, mesh.sdf, eps, mesh.mu0, mesh.mu1, mesh.solid)

    # Print SDF and BDIM-style ranges to catch sign or layout mistakes.
    c = mesh.leaf_ids[0]
    sdf_min = mesh.sdf[c]
    sdf_max = mesh.sdf[c]
    mu0_min = mesh.mu0[c]
    mu0_max = mesh.mu0[c]
    solid_count = 0
    fluid_count = 0
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        if mesh.sdf[c] < sdf_min:
            sdf_min = mesh.sdf[c]
        if mesh.sdf[c] > sdf_max:
            sdf_max = mesh.sdf[c]
        if mesh.mu0[c] < mu0_min:
            mu0_min = mesh.mu0[c]
        if mesh.mu0[c] > mu0_max:
            mu0_max = mesh.mu0[c]
        if mesh.mu0[c] < 0.01:
            solid_count += 1
        if mesh.mu0[c] > 0.99:
            fluid_count += 1
    mu0_at_sdf_min = fvc_bdim_mu0(sdf_min, eps)
    print("BDIM-style eps:", eps)
    print("Sampled SDF min/max:", sdf_min, sdf_max)
    print("mu0 at sampled SDF min:", mu0_at_sdf_min)
    print("BDIM-style mu0 min/max:", mu0_min, mu0_max)
    print("BDIM-style solid/fluid leaf counts:", solid_count, fluid_count)

    ### -------------------------------------------------- ###
    ### ----- Allocate and initialize working arrays ----- ###
    ### -------------------------------------------------- ###

    allocate(phi,         mesh.cell_capacity, 6)
    allocate(phiHbyA,     mesh.cell_capacity, 6)
    allocate(nu_face,     mesh.cell_capacity, 6)
    allocate(invA,        mesh.cell_capacity)
    allocate(hbyA,        mesh.cell_capacity, 3)
    allocate(hbyA_comp,   mesh.cell_capacity)
    allocate(u_old,       mesh.cell_capacity, 3)
    allocate(u_comp,      mesh.cell_capacity)
    allocate(u_mag,       mesh.cell_capacity)
    allocate(div_phiHbyA, mesh.cell_capacity)
    allocate(div_diag,    mesh.cell_capacity)
    allocate(yPlus,       mesh.cell_capacity)

    phi         = 0.0
    phiHbyA     = 0.0
    invA        = 0.0
    hbyA        = 0.0
    hbyA_comp   = 0.0
    u_old       = 0.0
    u_comp      = 0.0
    u_mag       = 0.0
    div_phiHbyA = 0.0
    div_diag    = 0.0
    yPlus       = 0.0
    nu_face     = nu

    # Initial velocity: flow enters from the +X inlet toward -X.
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        mesh.u[c, 0] = u_inlet_x * mesh.mu0[c]
        mesh.u[c, 1] = 0.0
        mesh.u[c, 2] = 0.0
    mesh.p = 0.0

    # Print the initialized velocity before the solver can modify it.
    fvc_vector_mag(mesh, mesh.u, u_mag)
    u_mag_max = 0.0
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        if u_mag[c] > u_mag_max:
            u_mag_max = u_mag[c]
    print(f"initial |u|_max = {u_mag_max:.4e}")

    # Calculate dt from the finest cell width and requested Courant limit.
    if u_mag_max <= min_dt_speed:
        print("Error: cannot calculate dt from zero velocity magnitude.")
        exit(1)
    dt = max_courant * ref_dx / u_mag_max
    print(f"Calculated dt = {dt:.6e} from Co_max={max_courant:.4f}")

    fvm_equation_init(mom_eq, mesh)
    fvm_equation_init(p_eq, mesh)

    print(f"Starting PIMPLE loop: {n_steps} steps, dt={dt:.6e}, nu={nu:.4f}")

    # Pre-simulation yPlus diagnostics on the initial velocity field.
    fvc_yPlus(mesh, mesh.u, normal, mesh.sdf, mesh.mu0, nu, yPlus)
    yPlus_min = 1.0e30
    yPlus_max = 0.0
    yPlus_sum = 0.0
    yPlus_near_body_count = 0
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        if yPlus[c] > 0.0:
            yPlus_near_body_count += 1
            if yPlus[c] < yPlus_min:
                yPlus_min = yPlus[c]
            if yPlus[c] > yPlus_max:
                yPlus_max = yPlus[c]
            yPlus_sum += yPlus[c]
    if yPlus_near_body_count > 0:
        print(f"pre-sim  yPlus near-body: min={yPlus_min:.4e} max={yPlus_max:.4e} avg={yPlus_sum/yPlus_near_body_count:.4e} cells={yPlus_near_body_count}")
    else:
        print("pre-sim  yPlus: no near-body cells with yPlus > 0 (initial velocity is uniform)")

    ### ---------------------------- ###
    ### ----- PIMPLE time loop ----- ###
    ### ---------------------------- ###

    for step in range(n_steps):

        # Save velocity at start of time step.
        for l in range(mesh.num_leaves):
            c = mesh.leaf_ids[l]
            u_old[c, 0] = mesh.u[c, 0]
            u_old[c, 1] = mesh.u[c, 1]
            u_old[c, 2] = mesh.u[c, 2]

        # Convecting flux for momentum: reuse the divergence-free face flux
        # produced by the previous step's pressure correction (phiHbyA) instead
        # of rebuilding a non-conservative flux from the cell velocity.
        phi = phiHbyA

        # Diagnostic: divergence of the convecting flux; this should stay near zero
        fvc_div_flux(mesh, phi, div_diag)
        div_phi_max = 0.0
        for l in range(mesh.num_leaves):
            c = mesh.leaf_ids[l]
            if abs(div_diag[c]) > div_phi_max:
                div_phi_max = abs(div_diag[c])
        print(f"step {step}: max|div(phi_conv)| = {div_phi_max:.4e}")

        # Momentum predictor: solve each component, then form HbyA = H(u)/A
        # from that component's assembled equation. The diagonal A includes
        # ddt, convection, diffusion, the BDIM-style penalty, and under-relaxation
        for k in range(3):
            for l in range(mesh.num_leaves):
                c = mesh.leaf_ids[l]
                u_comp[c] = u_old[c, k]

            fvm_equation_zero(mom_eq)
            fvm_momentum_component(mom_eq, mesh, u_comp, phi, nu_face, dt)
            # Apply the known inflow value to upwind boundary convection.
            if k == 0:
                fvm_div_dirichlet(mom_eq, mesh, phi, 1, u_inlet_x)
            else:
                fvm_div_dirichlet(mom_eq, mesh, phi, 1, 0.0)
            # Drive the inflow boundary on the +X face.
            if k == 0:
                fvm_dirichlet(mom_eq, mesh, nu_face, 1, u_inlet_x)
            else:
                fvm_dirichlet(mom_eq, mesh, nu_face, 1, 0.0)
            fvm_bdim_static_body_penalty(mom_eq, mesh, mesh.mu0, penalty, 0.0) # NOTE: This body penalty is a work in progress
            fvm_under_relax(mom_eq, mesh, u_comp, alpha_u)
            fvm_solve_bicgstab(mom_eq, mesh, u_comp, mom_tol, mom_max_iter)

            for l in range(mesh.num_leaves):
                c = mesh.leaf_ids[l]
                mesh.u[c, k] = u_comp[c]

            # HbyA for this component: invA = 1/A, H(u) = rhs - sum_nb(A_nb u_nb),
            # hbyA = H(u) * invA. A is the same for every component, so invA
            # computed here is also reused for the pressure correction below.
            fvc_inverse_diag(mesh, mom_eq, invA)
            fvc_HbyA_component(mesh, mom_eq, u_comp, invA, hbyA_comp)
            for l in range(mesh.num_leaves):
                c = mesh.leaf_ids[l]
                hbyA[c, k] = hbyA_comp[c]

        # Diagnostic before BDIM-style blend and pressure corrections.
        fvc_vector_mag(mesh, mesh.u, u_mag)
        u_pred_max = 0.0
        for l in range(mesh.num_leaves):
            c = mesh.leaf_ids[l]
            if u_mag[c] > u_pred_max:
                u_pred_max = u_mag[c]
        print(f"step {step}: |u|_predictor = {u_pred_max:.4e}")

        # Blend the static body into HbyA so the immersed boundary enters the
        # projection flux (BDIM-style), instead of blending the bare velocity.
        fvc_bdim_apply_static_body(mesh, hbyA, normal, mesh.mu0, mesh.mu1, hbyA)

        # Pressure correction: HbyA = H(u)/A was formed in the predictor loop;
        # invA holds 1/A. Build the HbyA flux before solving pressure.
        fvc_flux_from_hbyA(mesh, hbyA, phiHbyA)

        for corr in range(n_corr):
            fvc_div_flux(mesh, phiHbyA, div_phiHbyA)

            fvm_equation_zero(p_eq)
            fvm_pressure_laplacian_invA(p_eq, mesh, invA)

            # RHS = -sum_f(phiHbyA): the assembled Laplacian has sign convention
            # sum_f(invA*A/d*(p[c]-p[nb])) = rhs, so set rhs = -div(phiHbyA)*vol.
            fvm_add_to_rhs(p_eq, mesh, -1.0, div_phiHbyA)

            # Dirichlet p=0 at outlet (-X boundary, face index 0).
            fvm_pressure_dirichlet_invA(p_eq, mesh, invA, 0, 0.0)
            fvm_solve_cg(p_eq, mesh, mesh.p, p_tol, p_max_iter)

            fvc_pressure_flux_correction_dirichlet_invA(mesh, mesh.p, invA, phiHbyA, 0, 0.0, phiHbyA)

        # Velocity correction from pressure gradient.
        fvc_momentum_pressure_correct(mesh, hbyA, invA, mesh.p, mesh.u)

        # Diagnostic: divergence of the corrected cell velocity
        # A large value here indicates pressure-velocity decoupling
        fvc_div(mesh, mesh.u, div_diag)
        div_u_max = 0.0
        for l in range(mesh.num_leaves):
            c = mesh.leaf_ids[l]
            if abs(div_diag[c]) > div_u_max:
                div_u_max = abs(div_diag[c])
        print(f"step {step}: max|div(u_cell)| = {div_u_max:.4e}")

        # Diagnostic before the final BDIM-style correction.
        fvc_vector_mag(mesh, mesh.u, u_mag)
        u_corr_max = 0.0
        for l in range(mesh.num_leaves):
            c = mesh.leaf_ids[l]
            if u_mag[c] > u_corr_max:
                u_corr_max = u_mag[c]
        print(f"step {step}: |u|_pressure = {u_corr_max:.4e}")

        # Final BDIM-style correction.
        fvc_bdim_apply_static_body(mesh, mesh.u, normal, mesh.mu0, mesh.mu1, mesh.u)

        # Diagnostic: max velocity magnitude over active leaves.
        fvc_vector_mag(mesh, mesh.u, u_mag)
        u_mag_max = 0.0
        for l in range(mesh.num_leaves):
            c = mesh.leaf_ids[l]
            if u_mag[c] > u_mag_max:
                u_mag_max = u_mag[c]
        print(f"step {step}: |u|_max = {u_mag_max:.4e}")

    print("PIMPLE loop complete.")

    # Post-simulation yPlus diagnostics on the final velocity field.
    fvc_yPlus(mesh, mesh.u, normal, mesh.sdf, mesh.mu0, nu, yPlus)
    yPlus_min = 1.0e30
    yPlus_max = 0.0
    yPlus_sum = 0.0
    yPlus_near_body_count = 0
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        if yPlus[c] > 0.0:
            yPlus_near_body_count += 1
            if yPlus[c] < yPlus_min:
                yPlus_min = yPlus[c]
            if yPlus[c] > yPlus_max:
                yPlus_max = yPlus[c]
            yPlus_sum += yPlus[c]
    if yPlus_near_body_count > 0:
        print(f"post-sim yPlus near-body: min={yPlus_min:.4e} max={yPlus_max:.4e} avg={yPlus_sum/yPlus_near_body_count:.4e} cells={yPlus_near_body_count}")
    else:
        print("post-sim yPlus: no near-body cells with yPlus > 0")
    # Print flow regime classification.
    if yPlus_near_body_count > 0:
        viscous_cells = 0
        buffer_cells = 0
        loglayer_cells = 0
        for l in range(mesh.num_leaves):
            c = mesh.leaf_ids[l]
            yp = yPlus[c]
            if yp <= 1.0:
                viscous_cells += 1
            elif yp <= 5.0:
                buffer_cells += 1
            else:
                loglayer_cells += 1
        print(f"yPlus regimes: viscous<=1: {viscous_cells}, buffer 1-5: {buffer_cells}, log-layer>5: {loglayer_cells}")

    ### ------------------------------------------- ###
    ### ----- Export XDMF + HDF5 for ParaView ----- ###
    ### ------------------------------------------- ###

    allocate(points,      3, 8 * mesh.num_leaves)
    allocate(connectivity, 8, mesh.num_leaves)
    allocate(leaf_p,     mesh.num_leaves)
    allocate(leaf_u_x,   mesh.num_leaves)
    allocate(leaf_u_y,   mesh.num_leaves)
    allocate(leaf_u_z,   mesh.num_leaves)
    allocate(leaf_umag,  mesh.num_leaves)
    allocate(leaf_omega_x,   mesh.num_leaves)
    allocate(leaf_omega_y,   mesh.num_leaves)
    allocate(leaf_omega_z,   mesh.num_leaves)
    allocate(leaf_omega_mag, mesh.num_leaves)
    allocate(leaf_sdf,   mesh.num_leaves)
    allocate(leaf_mu0,   mesh.num_leaves)
    allocate(leaf_mu1,   mesh.num_leaves)
    allocate(leaf_solid, mesh.num_leaves)
    allocate(leaf_yPlus, mesh.num_leaves)
    allocate(omega,      mesh.cell_capacity, 3)
    allocate(omega_mag,  mesh.cell_capacity)

    geom_cartesian_leaf_corners(mesh, points, connectivity)
    h5write("body_pimple.h5", "/points",       points)
    h5write("body_pimple.h5", "/connectivity", connectivity)

    # Build derived export fields on the final leaf mesh.
    fvc_vorticity(mesh, mesh.u, omega)
    fvc_vector_mag(mesh, mesh.u, u_mag)
    fvc_vector_mag(mesh, omega, omega_mag)
    geom_cartesian_leaf_field(mesh, mesh.p,     leaf_p)
    geom_cartesian_leaf_field(mesh, u_mag,      leaf_umag)
    geom_cartesian_leaf_field(mesh, omega_mag,  leaf_omega_mag)
    geom_cartesian_leaf_field(mesh, mesh.sdf,   leaf_sdf)
    geom_cartesian_leaf_field(mesh, mesh.mu0,   leaf_mu0)
    geom_cartesian_leaf_field(mesh, mesh.mu1,   leaf_mu1)
    geom_cartesian_leaf_field(mesh, mesh.solid, leaf_solid)
    geom_cartesian_leaf_field(mesh, yPlus,      leaf_yPlus)

    # Copy vector components to scalar leaf arrays for XDMF cell attributes.
    for l in range(mesh.num_leaves):
        c = mesh.leaf_ids[l]
        leaf_u_x[l] = mesh.u[c, 0]
        leaf_u_y[l] = mesh.u[c, 1]
        leaf_u_z[l] = mesh.u[c, 2]
        leaf_omega_x[l] = omega[c, 0]
        leaf_omega_y[l] = omega[c, 1]
        leaf_omega_z[l] = omega[c, 2]

    h5write("body_pimple.h5", "/p",         leaf_p)
    h5write("body_pimple.h5", "/u_x",       leaf_u_x)
    h5write("body_pimple.h5", "/u_y",       leaf_u_y)
    h5write("body_pimple.h5", "/u_z",       leaf_u_z)
    h5write("body_pimple.h5", "/u_mag",     leaf_umag)
    h5write("body_pimple.h5", "/omega_x",   leaf_omega_x)
    h5write("body_pimple.h5", "/omega_y",   leaf_omega_y)
    h5write("body_pimple.h5", "/omega_z",   leaf_omega_z)
    h5write("body_pimple.h5", "/omega_mag", leaf_omega_mag)
    h5write("body_pimple.h5", "/sdf",       leaf_sdf)
    h5write("body_pimple.h5", "/mu0",       leaf_mu0)
    h5write("body_pimple.h5", "/mu1",       leaf_mu1)
    h5write("body_pimple.h5", "/solid",     leaf_solid)
    h5write("body_pimple.h5", "/yPlus",     leaf_yPlus)

    xdmf_add_unstructured(xdmf_xml, points, connectivity)
    xdmf_add_cell(xdmf_xml, "p",         leaf_p)
    xdmf_add_cell(xdmf_xml, "u_x",       leaf_u_x)
    xdmf_add_cell(xdmf_xml, "u_y",       leaf_u_y)
    xdmf_add_cell(xdmf_xml, "u_z",       leaf_u_z)
    xdmf_add_cell(xdmf_xml, "u_mag",     leaf_umag)
    xdmf_add_cell(xdmf_xml, "omega_x",   leaf_omega_x)
    xdmf_add_cell(xdmf_xml, "omega_y",   leaf_omega_y)
    xdmf_add_cell(xdmf_xml, "omega_z",   leaf_omega_z)
    xdmf_add_cell(xdmf_xml, "omega_mag", leaf_omega_mag)
    xdmf_add_cell(xdmf_xml, "sdf",       leaf_sdf)
    xdmf_add_cell(xdmf_xml, "mu0",       leaf_mu0)
    xdmf_add_cell(xdmf_xml, "mu1",       leaf_mu1)
    xdmf_add_cell(xdmf_xml, "solid",     leaf_solid)
    xdmf_add_cell(xdmf_xml, "yPlus",     leaf_yPlus)
    xdmf_write("body_pimple.xdmf", "body_pimple.h5", xdmf_xml)

    print("Wrote body_pimple.h5 and body_pimple.xdmf")
    print("Open body_pimple.xdmf in ParaView to visualize.")

(* Generated helper templates live here so codegen.ml stays focused on lowering logic. *)

let gen_plot_helper () =
  String.concat "" [
    "  subroutine fortscript_plot_xy__(x, y, filename, title, xlabel, ylabel)\n";
    "    use pyplot_module, only: pyplot\n";
    "    implicit none\n";
    "    real(8), intent(in) :: x(:)\n";
    "    real(8), intent(in) :: y(:)\n";
    "    character(len=*), intent(in) :: filename\n";
    "    character(len=*), intent(in) :: title\n";
    "    character(len=*), intent(in) :: xlabel\n";
    "    character(len=*), intent(in) :: ylabel\n";
    "    type(pyplot) :: plt  ! Local plotting handle\n";
    "\n";
    "    call plt%initialize(grid=.true., xlabel=trim(xlabel), ylabel=trim(ylabel), &\n";
    "                        title=trim(title), legend=.false.)\n";
    "    call plt%add_plot(x, y, label='', linestyle='b-')  ! Single line plot\n";
    "    call plt%savefig(trim(filename), python='python3')  ! Write the figure to disk\n";
    "  end subroutine fortscript_plot_xy__\n"
  ]

let gen_histogram_helper () =
  String.concat "" [
    "  subroutine fortscript_histogram__(x, filename, title, xlabel, ylabel, bins)\n";
    "    use pyplot_module, only: pyplot\n";
    "    implicit none\n";
    "    real(8), intent(in) :: x(:)\n";
    "    character(len=*), intent(in) :: filename\n";
    "    character(len=*), intent(in) :: title\n";
    "    character(len=*), intent(in) :: xlabel\n";
    "    character(len=*), intent(in) :: ylabel\n";
    "    integer, intent(in) :: bins  ! Number of histogram bins\n";
    "    type(pyplot) :: plt  ! Local plotting handle\n";
    "\n";
    "    call plt%initialize(grid=.true., xlabel=trim(xlabel), ylabel=trim(ylabel), &\n";
    "                        title=trim(title), legend=.false.)\n";
    "    call plt%add_hist(x, label='', bins=bins)  ! Histogram with given bin count\n";
    "    call plt%savefig(trim(filename), python='python3')  ! Write the figure to disk\n";
    "  end subroutine fortscript_histogram__\n"
  ]

let gen_scatter_helper () =
  String.concat "" [
    "  subroutine fortscript_scatter__(x, y, filename, title, xlabel, ylabel)\n";
    "    use pyplot_module, only: pyplot\n";
    "    implicit none\n";
    "    real(8), intent(in) :: x(:)\n";
    "    real(8), intent(in) :: y(:)\n";
    "    character(len=*), intent(in) :: filename\n";
    "    character(len=*), intent(in) :: title\n";
    "    character(len=*), intent(in) :: xlabel\n";
    "    character(len=*), intent(in) :: ylabel\n";
    "    type(pyplot) :: plt  ! Local plotting handle\n";
    "\n";
    "    call plt%initialize(grid=.true., xlabel=trim(xlabel), ylabel=trim(ylabel), &\n";
    "                        title=trim(title), legend=.false.)\n";
    "    call plt%add_plot(x, y, label='', linestyle='o')  ! Scatter: markers only, no connecting line\n";
    "    call plt%savefig(trim(filename), python='python3')  ! Write the figure to disk\n";
    "  end subroutine fortscript_scatter__\n"
  ]

let gen_imshow_helper () =
  String.concat "" [
    "  subroutine fortscript_imshow__(z, filename, title, xlabel, ylabel)\n";
    "    use pyplot_module, only: pyplot\n";
    "    implicit none\n";
    "    real(8), intent(in) :: z(:, :)\n";
    "    character(len=*), intent(in) :: filename\n";
    "    character(len=*), intent(in) :: title\n";
    "    character(len=*), intent(in) :: xlabel\n";
    "    character(len=*), intent(in) :: ylabel\n";
    "    type(pyplot) :: plt  ! Local plotting handle\n";
    "\n";
    "    call plt%initialize(title=trim(title), xlabel=trim(xlabel), ylabel=trim(ylabel), &\n";
    "                        legend=.false., use_numpy=.true.)  ! use_numpy required by add_imshow\n";
    "    call plt%add_imshow(z)  ! Render 2-D array as a heatmap\n";
    "    call plt%savefig(trim(filename), python='python3')  ! Write the figure to disk\n";
    "  end subroutine fortscript_imshow__\n"
  ]

(* Shared helper for contour and contourf; pass filled=.true. for contourf. *)
let gen_contour_helper () =
  String.concat "" [
    "  subroutine fortscript_contour__(x, y, z, filename, title, xlabel, ylabel, filled)\n";
    "    use pyplot_module, only: pyplot\n";
    "    implicit none\n";
    "    real(8), intent(in) :: x(:)\n";
    "    real(8), intent(in) :: y(:)\n";
    "    real(8), intent(in) :: z(:, :)\n";
    "    character(len=*), intent(in) :: filename\n";
    "    character(len=*), intent(in) :: title\n";
    "    character(len=*), intent(in) :: xlabel\n";
    "    character(len=*), intent(in) :: ylabel\n";
    "    logical, intent(in) :: filled  ! .true. -> contourf, .false. -> contour\n";
    "    type(pyplot) :: plt  ! Local plotting handle\n";
    "\n";
    "    call plt%initialize(grid=.true., xlabel=trim(xlabel), ylabel=trim(ylabel), &\n";
    "                        title=trim(title), legend=.false., use_numpy=.true.)  ! use_numpy required by add_contour\n";
    "    call plt%add_contour(x, y, z, linestyle='-', filled=filled, colorbar=.true.)  ! Contour lines or filled regions\n";
    "    call plt%savefig(trim(filename), python='python3')  ! Write the figure to disk\n";
    "  end subroutine fortscript_contour__\n"
  ]

let gen_xdmf_helpers () =
  String.concat "" [
    "  pure function fortscript_xdmf_int__(n) result(out)\n";
    "    implicit none\n";
    "    integer, intent(in) :: n\n";
    "    character(len=:), allocatable :: out\n";
    "    character(len=32) :: buf\n";
    "\n";
    "    write(buf, '(i0)') n\n";
    "    out = trim(buf)\n";
    "  end function fortscript_xdmf_int__\n";
    "\n";
    "  pure function fortscript_xdmf_replace__(source, pattern, replacement) result(out)\n";
    "    implicit none\n";
    "    character(len=*), intent(in) :: source\n";
    "    character(len=*), intent(in) :: pattern\n";
    "    character(len=*), intent(in) :: replacement\n";
    "    character(len=:), allocatable :: out\n";
    "    integer :: pos\n";
    "    integer :: start_idx\n";
    "    integer :: rel_pos\n";
    "\n";
    "    if (len(pattern) == 0) then\n";
    "      out = source\n";
    "      return\n";
    "    end if\n";
    "\n";
    "    out = ''\n";
    "    start_idx = 1\n";
    "    do while (start_idx <= len(source))\n";
    "      rel_pos = index(source(start_idx:), pattern)\n";
    "      if (rel_pos == 0) exit\n";
    "      pos = start_idx + rel_pos - 1\n";
    "      if (pos > start_idx) out = out // source(start_idx:pos - 1)\n";
    "      out = out // replacement\n";
    "      start_idx = pos + len(pattern)\n";
    "    end do\n";
    "    if (start_idx <= len(source)) out = out // source(start_idx:)\n";
    "  end function fortscript_xdmf_replace__\n";
    "\n";
    "  pure subroutine fortscript_xdmf_typeinfo__(values, number_type, precision_str)\n";
    "    implicit none\n";
    "    class(*), intent(in) :: values(..)\n";
    "    character(len=:), allocatable, intent(out) :: number_type\n";
    "    character(len=:), allocatable, intent(out) :: precision_str\n";
    "\n";
    "    select rank (typed_values => values)\n";
    "    rank (1)\n";
    "      select type (typed_values)\n";
    "      type is (real(8))\n";
    "        number_type = 'Float'\n";
    "        precision_str = '8'\n";
    "      type is (integer)\n";
    "        number_type = 'Int'\n";
    "        precision_str = fortscript_xdmf_int__(storage_size(typed_values) / 8)\n";
    "      class default\n";
    "        error stop 'XDMF only supports integer and float arrays here'\n";
    "      end select\n";
    "    rank (3)\n";
    "      select type (typed_values)\n";
    "      type is (real(8))\n";
    "        number_type = 'Float'\n";
    "        precision_str = '8'\n";
    "      type is (integer)\n";
    "        number_type = 'Int'\n";
    "        precision_str = fortscript_xdmf_int__(storage_size(typed_values) / 8)\n";
    "      class default\n";
    "        error stop 'XDMF only supports integer and float arrays here'\n";
    "      end select\n";
    "    rank default\n";
    "      error stop 'XDMF type info only supports rank-1 and rank-3 arrays'\n";
    "    end select\n";
    "  end subroutine fortscript_xdmf_typeinfo__\n";
    "\n";
    "  subroutine fortscript_xdmf_add__(xml_str, field_name, field_array)\n";
    "    implicit none\n";
    "    character(len=:), allocatable, intent(inout) :: xml_str\n";
    "    character(len=*), intent(in) :: field_name\n";
    "    class(*), intent(in) :: field_array(..)\n";
    "    character(len=:), allocatable :: dims_str\n";
    "    character(len=:), allocatable :: number_type\n";
    "    character(len=:), allocatable :: precision_str\n";
    "    character(len=:), allocatable :: fragment\n";
    "    character(len=1), parameter :: nl = achar(10)\n";
    "\n";
    "    if (.not. allocated(xml_str)) xml_str = ''\n";
    "\n";
    "    select rank (field_array)\n";
    "    rank (3)\n";
    "      dims_str = fortscript_xdmf_int__(size(field_array, 1)) // ' ' // &\n";
    "                 fortscript_xdmf_int__(size(field_array, 2)) // ' ' // &\n";
    "                 fortscript_xdmf_int__(size(field_array, 3))\n";
    "      call fortscript_xdmf_typeinfo__(field_array, number_type, precision_str)\n";
    "    rank default\n";
    "      error stop 'xdmf_add(): only rank-3 arrays are supported'\n";
    "    end select\n";
    "\n";
    "    fragment = '      <Attribute Name=\"' // trim(field_name) // '\" AttributeType=\"Scalar\" Center=\"Node\">' // nl // &\n";
    "               '        <DataItem Dimensions=\"' // dims_str // '\" NumberType=\"' // trim(number_type) // '\" Precision=\"' // trim(precision_str) // '\" Format=\"HDF\">__FORTSCRIPT_H5FILE__:/' // trim(field_name) // '</DataItem>' // nl // &\n";
    "               '      </Attribute>' // nl\n";
    "    xml_str = xml_str // fragment\n";
    "  end subroutine fortscript_xdmf_add__\n";
    "\n";
    "  subroutine fortscript_xdmf_add_xyz__(xml_str, x, y, z)\n";
    "    implicit none\n";
    "    character(len=:), allocatable, intent(inout) :: xml_str\n";
    "    class(*), intent(in) :: x(..)\n";
    "    class(*), intent(in) :: y(..)\n";
    "    class(*), intent(in) :: z(..)\n";
    "    character(len=:), allocatable :: x_dim\n";
    "    character(len=:), allocatable :: y_dim\n";
    "    character(len=:), allocatable :: z_dim\n";
    "    character(len=:), allocatable :: grid_dims\n";
    "    character(len=:), allocatable :: x_type\n";
    "    character(len=:), allocatable :: y_type\n";
    "    character(len=:), allocatable :: z_type\n";
    "    character(len=:), allocatable :: x_prec\n";
    "    character(len=:), allocatable :: y_prec\n";
    "    character(len=:), allocatable :: z_prec\n";
    "    character(len=:), allocatable :: fragment\n";
    "    character(len=1), parameter :: nl = achar(10)\n";
    "\n";
    "    if (.not. allocated(xml_str)) xml_str = ''\n";
    "\n";
    "    select rank (x)\n";
    "    rank (1)\n";
    "      x_dim = fortscript_xdmf_int__(size(x, 1))\n";
    "      call fortscript_xdmf_typeinfo__(x, x_type, x_prec)\n";
    "    rank default\n";
    "      error stop 'xdmf_add_xyz(): x must be rank 1'\n";
    "    end select\n";
    "\n";
    "    select rank (y)\n";
    "    rank (1)\n";
    "      y_dim = fortscript_xdmf_int__(size(y, 1))\n";
    "      call fortscript_xdmf_typeinfo__(y, y_type, y_prec)\n";
    "    rank default\n";
    "      error stop 'xdmf_add_xyz(): y must be rank 1'\n";
    "    end select\n";
    "\n";
    "    select rank (z)\n";
    "    rank (1)\n";
    "      z_dim = fortscript_xdmf_int__(size(z, 1))\n";
    "      call fortscript_xdmf_typeinfo__(z, z_type, z_prec)\n";
    "    rank default\n";
    "      error stop 'xdmf_add_xyz(): z must be rank 1'\n";
    "    end select\n";
    "\n";
    "    grid_dims = trim(z_dim) // ' ' // trim(y_dim) // ' ' // trim(x_dim)\n";
    "    fragment = '      <Topology TopologyType=\"3DRectMesh\" Dimensions=\"' // grid_dims // '\"/>' // nl // &\n";
    "               '      <Geometry GeometryType=\"VXVYVZ\">' // nl // &\n";
    "               '        <DataItem Dimensions=\"' // trim(x_dim) // '\" NumberType=\"' // trim(x_type) // '\" Precision=\"' // trim(x_prec) // '\" Format=\"HDF\">__FORTSCRIPT_H5FILE__:/x</DataItem>' // nl // &\n";
    "               '        <DataItem Dimensions=\"' // trim(y_dim) // '\" NumberType=\"' // trim(y_type) // '\" Precision=\"' // trim(y_prec) // '\" Format=\"HDF\">__FORTSCRIPT_H5FILE__:/y</DataItem>' // nl // &\n";
    "               '        <DataItem Dimensions=\"' // trim(z_dim) // '\" NumberType=\"' // trim(z_type) // '\" Precision=\"' // trim(z_prec) // '\" Format=\"HDF\">__FORTSCRIPT_H5FILE__:/z</DataItem>' // nl // &\n";
    "               '      </Geometry>' // nl\n";
    "    xml_str = xml_str // fragment\n";
    "  end subroutine fortscript_xdmf_add_xyz__\n";
    "\n";
    "  subroutine fortscript_xdmf_write__(xdmf_filename, h5_filename, xml_str)\n";
    "    implicit none\n";
    "    character(len=*), intent(in) :: xdmf_filename\n";
    "    character(len=*), intent(in) :: h5_filename\n";
    "    character(len=*), intent(in) :: xml_str\n";
    "    character(len=:), allocatable :: expanded_xml\n";
    "    character(len=:), allocatable :: full_xml\n";
    "    character(len=1), parameter :: nl = achar(10)\n";
    "    integer :: unit\n";
    "\n";
    "    expanded_xml = fortscript_xdmf_replace__(xml_str, '__FORTSCRIPT_H5FILE__', trim(h5_filename))\n";
    "    full_xml = '<?xml version=\"1.0\" ?>' // nl // &\n";
    "               '<Xdmf Version=\"3.0\">' // nl // &\n";
    "               '  <Domain>' // nl // &\n";
    "               '    <Grid Name=\"fortscript_structured_grid\" GridType=\"Uniform\">' // nl // &\n";
    "               expanded_xml // &\n";
    "               '    </Grid>' // nl // &\n";
    "               '  </Domain>' // nl // &\n";
    "               '</Xdmf>' // nl\n";
    "\n";
    "    open(newunit=unit, file=trim(xdmf_filename), status='replace', action='write', access='stream', form='unformatted')\n";
    "    write(unit) full_xml\n";
    "    close(unit)\n";
    "  end subroutine fortscript_xdmf_write__\n"
  ]

let gen_lapack_qr_helper () =
  String.concat "" [
    "  subroutine fortscript_lapack_qr__(a, q, r)\n";
    "    implicit none\n";
    "    real(8), intent(in) :: a(:, :)\n";
    "    real(8), intent(out) :: q(:, :)\n";
    "    real(8), intent(out) :: r(:, :)\n";
    "    real(8), allocatable :: qr_work(:, :)  ! Working copy overwritten by LAPACK\n";
    "    real(8), allocatable :: q_work(:, :)  ! Compact Q buffer for dorgqr\n";
    "    real(8), allocatable :: tau(:)  ! Householder scalars from dgeqrf\n";
    "    real(8), allocatable :: work(:)  ! LAPACK workspace\n";
    "    real(8) :: work_query(1)  ! Workspace query result\n";
    "    integer :: m, n, k, lwork, info, i, j\n";
    "\n";
    "    interface\n";
    "      subroutine dgeqrf(m, n, a, lda, tau, work, lwork, info)\n";
    "        integer, intent(in) :: m, n, lda, lwork\n";
    "        integer, intent(out) :: info\n";
    "        real(8), intent(inout) :: a(lda, *)\n";
    "        real(8), intent(out) :: tau(*)\n";
    "        real(8), intent(inout) :: work(*)\n";
    "      end subroutine dgeqrf\n";
    "      subroutine dorgqr(m, n, k, a, lda, tau, work, lwork, info)\n";
    "        integer, intent(in) :: m, n, k, lda, lwork\n";
    "        integer, intent(out) :: info\n";
    "        real(8), intent(inout) :: a(lda, *)\n";
    "        real(8), intent(in) :: tau(*)\n";
    "        real(8), intent(inout) :: work(*)\n";
    "      end subroutine dorgqr\n";
    "    end interface\n";
    "\n";
    "    m = size(a, 1)\n";
    "    n = size(a, 2)\n";
    "    k = min(m, n)\n";
    "\n";
    "    if (size(q, 1) /= m .or. size(q, 2) /= k) then\n";
    "      error stop \"qr(): q must have shape (m, min(m, n))\"\n";
    "    end if\n";
    "    if (size(r, 1) /= k .or. size(r, 2) /= n) then\n";
    "      error stop \"qr(): r must have shape (min(m, n), n)\"\n";
    "    end if\n";
    "\n";
    "    q = 0.0d0\n";
    "    r = 0.0d0\n";
    "    if (k == 0) return  ! Zero-sized inputs need no LAPACK call.\n";
    "\n";
    "    allocate(qr_work(m, n))\n";
    "    allocate(tau(k))\n";
    "    qr_work = a\n";
    "\n";
    "    call dgeqrf(m, n, qr_work, m, tau, work_query, -1, info)\n";
    "    if (info /= 0) error stop \"qr(): dgeqrf workspace query failed\"\n";
    "    lwork = max(1, int(work_query(1)))\n";
    "    allocate(work(lwork))\n";
    "    call dgeqrf(m, n, qr_work, m, tau, work, lwork, info)\n";
    "    if (info /= 0) error stop \"qr(): dgeqrf failed\"\n";
    "\n";
    "    do i = 1, k\n";
    "      do j = i, n\n";
    "        r(i, j) = qr_work(i, j)  ! Copy the upper triangle into R.\n";
    "      end do\n";
    "    end do\n";
    "\n";
    "    allocate(q_work(m, k))\n";
    "    q_work = qr_work(:, 1:k)\n";
    "\n";
    "    deallocate(work)\n";
    "    call dorgqr(m, k, k, q_work, m, tau, work_query, -1, info)\n";
    "    if (info /= 0) error stop \"qr(): dorgqr workspace query failed\"\n";
    "    lwork = max(1, int(work_query(1)))\n";
    "    allocate(work(lwork))\n";
    "    call dorgqr(m, k, k, q_work, m, tau, work, lwork, info)\n";
    "    if (info /= 0) error stop \"qr(): dorgqr failed\"\n";
    "\n";
    "    q = q_work\n";
    "  end subroutine fortscript_lapack_qr__\n"
  ]

let gen_random_fill_helper () =
  String.concat "" [
    "  subroutine fortscript_random_fill__(x)\n";
    "    implicit none\n";
    "    real(8), intent(inout) :: x(:)\n";
    "\n";
    "    call random_number(x)\n";
    "  end subroutine fortscript_random_fill__\n"
  ]

let gen_uniform_fill_helper () =
  String.concat "" [
    "  subroutine fortscript_uniform_fill__(low, high, x)\n";
    "    implicit none\n";
    "    real(8), intent(in) :: low\n";
    "    real(8), intent(in) :: high\n";
    "    real(8), intent(inout) :: x(:)\n";
    "\n";
    "    call random_number(x)\n";
    "    x = low + (high - low) * x\n";
    "  end subroutine fortscript_uniform_fill__\n"
  ]

let gen_random_seed_helper () =
  String.concat "" [
    "  subroutine fortscript_random_seed__(s)\n";
    "    implicit none\n";
    "    integer, intent(in) :: s\n";
    "    integer :: seed_size\n";
    "    integer, allocatable :: seed_arr(:)\n";
    "\n";
    "    call random_seed(size=seed_size)\n";
    "    allocate(seed_arr(seed_size))\n";
    "    seed_arr = s\n";
    "    call random_seed(put=seed_arr)\n";
    "  end subroutine fortscript_random_seed__\n"
  ]

let gen_lapack_solve_helper () =
  String.concat "" [
    "  subroutine fortscript_lapack_solve__(a, b, x)\n";
    "    implicit none\n";
    "    real(8), intent(in) :: a(:, :)\n";
    "    real(8), intent(in) :: b(:)\n";
    "    real(8), intent(out) :: x(:)\n";
    "    real(8), allocatable :: a_work(:, :)  ! Working copy overwritten by LAPACK.\n";
    "    real(8), allocatable :: rhs_work(:, :)  ! 2D RHS buffer because dgesv expects NRHS columns.\n";
    "    integer, allocatable :: ipiv(:)  ! Pivot indices returned by dgesv.\n";
    "    integer :: n, info\n";
    "\n";
    "    interface\n";
    "      subroutine dgesv(n, nrhs, a, lda, ipiv, b, ldb, info)\n";
    "        integer, intent(in) :: n, nrhs, lda, ldb\n";
    "        integer, intent(out) :: info\n";
    "        integer, intent(inout) :: ipiv(*)\n";
    "        real(8), intent(inout) :: a(lda, *)\n";
    "        real(8), intent(inout) :: b(ldb, *)\n";
    "      end subroutine dgesv\n";
    "    end interface\n";
    "\n";
    "    n = size(a, 1)\n";
    "\n";
    "    if (size(a, 2) /= n) then\n";
    "      error stop \"solve(): a must have shape (n, n)\"\n";
    "    end if\n";
    "    if (size(b) /= n) then\n";
    "      error stop \"solve(): b must have length n\"\n";
    "    end if\n";
    "    if (size(x) /= n) then\n";
    "      error stop \"solve(): x must have length n\"\n";
    "    end if\n";
    "\n";
    "    x = 0.0d0\n";
    "    if (n == 0) return  ! Zero-sized systems need no LAPACK call.\n";
    "\n";
    "    allocate(a_work(n, n))\n";
    "    allocate(rhs_work(n, 1))\n";
    "    allocate(ipiv(n))\n";
    "    a_work = a\n";
    "    rhs_work(:, 1) = b\n";
    "\n";
    "    call dgesv(n, 1, a_work, n, ipiv, rhs_work, n, info)\n";
    "    if (info < 0) error stop \"solve(): dgesv rejected an argument\"\n";
    "    if (info > 0) error stop \"solve(): matrix is singular to working precision\"\n";
    "\n";
    "    x = rhs_work(:, 1)\n";
    "  end subroutine fortscript_lapack_solve__\n"
  ]

let gen_lapack_svd_helper () =
  String.concat "" [
    "  subroutine fortscript_lapack_svd__(a, u, s, vt)\n";
    "    implicit none\n";
    "    real(8), intent(in) :: a(:, :)\n";
    "    real(8), intent(out) :: u(:, :)\n";
    "    real(8), intent(out) :: s(:)\n";
    "    real(8), intent(out) :: vt(:, :)\n";
    "    real(8), allocatable :: a_work(:, :)  ! Working copy overwritten by LAPACK\n";
    "    real(8), allocatable :: work(:)  ! LAPACK workspace\n";
    "    real(8) :: work_query(1)  ! Workspace query result\n";
    "    integer, allocatable :: iwork(:)  ! Integer workspace required by dgesdd\n";
    "    integer :: m, n, k, lwork, info\n";
    "    character(len=1) :: jobz\n";
    "\n";
    "    interface\n";
    "      subroutine dgesdd(jobz, m, n, a, lda, s, u, ldu, vt, ldvt, work, lwork, iwork, info)\n";
    "        character(len=1), intent(in) :: jobz\n";
    "        integer, intent(in) :: m, n, lda, ldu, ldvt, lwork\n";
    "        integer, intent(out) :: info\n";
    "        integer, intent(inout) :: iwork(*)\n";
    "        real(8), intent(inout) :: a(lda, *)\n";
    "        real(8), intent(out) :: s(*)\n";
    "        real(8), intent(out) :: u(ldu, *)\n";
    "        real(8), intent(out) :: vt(ldvt, *)\n";
    "        real(8), intent(inout) :: work(*)\n";
    "      end subroutine dgesdd\n";
    "    end interface\n";
    "\n";
    "    m = size(a, 1)\n";
    "    n = size(a, 2)\n";
    "    k = min(m, n)\n";
    "    jobz = 'S'  ! Reduced SVD, matching numpy.linalg.svd(..., full_matrices=False).\n";
    "\n";
    "    if (size(u, 1) /= m .or. size(u, 2) /= k) then\n";
    "      error stop \"svd(): u must have shape (m, min(m, n))\"\n";
    "    end if\n";
    "    if (size(s) /= k) then\n";
    "      error stop \"svd(): s must have length min(m, n)\"\n";
    "    end if\n";
    "    if (size(vt, 1) /= k .or. size(vt, 2) /= n) then\n";
    "      error stop \"svd(): vt must have shape (min(m, n), n)\"\n";
    "    end if\n";
    "\n";
    "    u = 0.0d0\n";
    "    s = 0.0d0\n";
    "    vt = 0.0d0\n";
    "    if (k == 0) return  ! Zero-sized inputs need no LAPACK call.\n";
    "\n";
    "    allocate(a_work(m, n))\n";
    "    allocate(iwork(8 * k))\n";
    "    a_work = a\n";
    "\n";
    "    call dgesdd(jobz, m, n, a_work, m, s, u, m, vt, k, work_query, -1, iwork, info)\n";
    "    if (info /= 0) error stop \"svd(): dgesdd workspace query failed\"\n";
    "    lwork = max(1, int(work_query(1)))\n";
    "    allocate(work(lwork))\n";
    "    call dgesdd(jobz, m, n, a_work, m, s, u, m, vt, k, work, lwork, iwork, info)\n";
    "    if (info /= 0) error stop \"svd(): dgesdd failed\"\n";
    "  end subroutine fortscript_lapack_svd__\n"
  ]

(* Eigendecomposition helper backed by LAPACK dgeev. *)
let gen_lapack_eig_helper () =
  String.concat "" [
    "  subroutine fortscript_lapack_eig__(a, wr, wi, vr)\n";
    "    implicit none\n";
    "    real(8), intent(in) :: a(:, :)\n";
    "    real(8), intent(out) :: wr(:)  ! Real parts of eigenvalues\n";
    "    real(8), intent(out) :: wi(:)  ! Imaginary parts of eigenvalues\n";
    "    real(8), intent(out) :: vr(:, :)  ! Right eigenvectors (LAPACK packed layout)\n";
    "    real(8), allocatable :: a_work(:, :)  ! Working copy overwritten by LAPACK\n";
    "    real(8), allocatable :: work(:)  ! LAPACK workspace\n";
    "    real(8) :: work_query(1)  ! Workspace query result\n";
    "    real(8) :: vl_dummy(1, 1)  ! Unused left-eigenvector buffer\n";
    "    integer :: n, lwork, info\n";
    "\n";
    "    interface\n";
    "      subroutine dgeev(jobvl, jobvr, n, a, lda, wr, wi, vl, ldvl, vr, ldvr, work, lwork, info)\n";
    "        character(len=1), intent(in) :: jobvl, jobvr\n";
    "        integer, intent(in) :: n, lda, ldvl, ldvr, lwork\n";
    "        integer, intent(out) :: info\n";
    "        real(8), intent(inout) :: a(lda, *)\n";
    "        real(8), intent(out) :: wr(*), wi(*)\n";
    "        real(8), intent(out) :: vl(ldvl, *)\n";
    "        real(8), intent(out) :: vr(ldvr, *)\n";
    "        real(8), intent(inout) :: work(*)\n";
    "      end subroutine dgeev\n";
    "    end interface\n";
    "\n";
    "    n = size(a, 1)\n";
    "\n";
    "    if (size(a, 2) /= n) then\n";
    "      error stop \"eig(): a must have shape (n, n)\"\n";
    "    end if\n";
    "    if (size(wr) /= n) then\n";
    "      error stop \"eig(): wr must have length n\"\n";
    "    end if\n";
    "    if (size(wi) /= n) then\n";
    "      error stop \"eig(): wi must have length n\"\n";
    "    end if\n";
    "    if (size(vr, 1) /= n .or. size(vr, 2) /= n) then\n";
    "      error stop \"eig(): vr must have shape (n, n)\"\n";
    "    end if\n";
    "\n";
    "    wr = 0.0d0\n";
    "    wi = 0.0d0\n";
    "    vr = 0.0d0\n";
    "    if (n == 0) return  ! Zero-sized inputs need no LAPACK call.\n";
    "\n";
    "    allocate(a_work(n, n))\n";
    "    a_work = a  ! dgeev overwrites its input.\n";
    "\n";
    "    call dgeev('N', 'V', n, a_work, n, wr, wi, vl_dummy, 1, vr, n, work_query, -1, info)\n";
    "    if (info /= 0) error stop \"eig(): dgeev workspace query failed\"\n";
    "    lwork = max(1, int(work_query(1)))\n";
    "    allocate(work(lwork))\n";
    "    call dgeev('N', 'V', n, a_work, n, wr, wi, vl_dummy, 1, vr, n, work, lwork, info)\n";
    "    if (info < 0) error stop \"eig(): dgeev rejected an argument\"\n";
    "    if (info > 0) error stop \"eig(): dgeev failed to converge\"\n";
    "  end subroutine fortscript_lapack_eig__\n"
  ]

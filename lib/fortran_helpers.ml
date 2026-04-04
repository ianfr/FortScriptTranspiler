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

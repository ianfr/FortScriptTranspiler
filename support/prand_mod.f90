! Hand-written modern-Fortran wrapper around the prand C library.
! prand (https://github.com/cheng-zhao/prand, MIT) is a parallel random number
! generator with multiple streams and jump-ahead. This module exposes a small
! Fortran API that the FortScript transpiler lowers support.random calls to.
!
! The transpiler emits "use prand_mod" whenever a program imports support.random,
! and the build links the prand static library (libprand.a) alongside this module
! (see dependencies.sh / env-setup.sh / the Makefiles).
!
! prand exposes its generator through a heap-allocated prand_t struct whose
! sampling routines are C function pointers. There is no C shim: this module
! mirrors the C struct as a bind(c) derived type, binds prand_init/prand_destroy
! directly, and calls the function pointers through c_f_procpointer.
!
! Two generators are kept as module state:
!   serial_rng - a single-stream generator for serial fills and scalar draws.
!   par_rng    - a multi-stream generator (one stream per OpenMP thread) used by
!                prand_uniform_thread inside @omp loops.

module prand_mod
  use, intrinsic :: iso_c_binding
  use omp_lib, only: omp_get_thread_num, omp_get_max_threads
  implicit none
  private

  public :: fortscript_random_seed__
  public :: fortscript_random_fill__
  public :: fortscript_uniform_fill__
  public :: fortscript_prand_uniform__
  public :: fortscript_prand_seed_parallel__
  public :: fortscript_prand_uniform_thread__

  ! prand_rng_enum from prand.h.
  integer(c_int), parameter :: PRAND_RNG_MRG32K3A = 0_c_int
  integer(c_int), parameter :: PRAND_RNG_MT19937  = 1_c_int

  ! Default generator (the prand example default) and default fallback seed.
  integer(c_int), parameter :: PRAND_DEFAULT_TYPE = PRAND_RNG_MT19937
  integer(c_int64_t), parameter :: PRAND_DEFAULT_SEED = 1_c_int64_t

  ! Distance between adjacent streams. Large enough that per-thread streams do
  ! not overlap during a run, well under the prand max single-jump of 2^63 - 1.
  integer(c_int64_t), parameter :: PRAND_STREAM_STEP = 1099511627776_c_int64_t  ! 2^40

  ! Mirror of the C prand_t struct (prand.h). Field order and kinds must match
  ! the C ABI exactly; every member is naturally aligned on a 64-bit target.
  type, bind(c) :: prand_t
    type(c_ptr) :: state            ! void *state
    type(c_ptr) :: state_stream     ! void **state_stream
    integer(c_int) :: nstream       ! int nstream
    integer(c_int) :: rtype         ! prand_rng_enum type (an int)
    integer(c_int64_t) :: rmin      ! int64_t min
    integer(c_int64_t) :: rmax      ! int64_t max
    type(c_funptr) :: get           ! uint64_t (*get)(void *)
    type(c_funptr) :: get_double    ! double (*get_double)(void *)
    type(c_funptr) :: get_double_pos! double (*get_double_pos)(void *)
    type(c_funptr) :: reset         ! void (*reset)(void *, uint64_t, uint64_t, int *)
    type(c_funptr) :: reset_all     ! void (*reset_all)(prand_t *, uint64_t, uint64_t, int *)
    type(c_funptr) :: jump          ! void (*jump)(void *, uint64_t, int *)
    type(c_funptr) :: jump_all      ! void (*jump_all)(prand_t *, uint64_t, int *)
  end type prand_t

  interface
    ! prand_t *prand_init(type, seed, nstream, step, int *err)
    function c_prand_init(rtype, seed, nstream, step, err) bind(c, name="prand_init")
      import :: c_ptr, c_int, c_int64_t
      integer(c_int), value :: rtype
      integer(c_int64_t), value :: seed
      integer(c_int), value :: nstream
      integer(c_int64_t), value :: step
      integer(c_int), intent(inout) :: err
      type(c_ptr) :: c_prand_init
    end function c_prand_init

    ! void prand_destroy(prand_t *rng)
    subroutine c_prand_destroy(rng) bind(c, name="prand_destroy")
      import :: c_ptr
      type(c_ptr), value :: rng
    end subroutine c_prand_destroy
  end interface

  ! Signature of the double (*get_double)(void *) sampling function pointer.
  abstract interface
    function prand_get_double_i(state) bind(c)
      import :: c_ptr, c_double
      type(c_ptr), value :: state
      real(c_double) :: prand_get_double_i
    end function prand_get_double_i
  end interface

  ! Module-level generator handles. c_null_ptr means "not yet initialised".
  type(c_ptr), save :: serial_rng = c_null_ptr
  type(c_ptr), save :: par_rng = c_null_ptr

contains

  ! Initialise (or reinitialise) the single-stream serial generator.
  subroutine init_serial(seed)
    integer(c_int64_t), intent(in) :: seed
    integer(c_int) :: err
    err = 0_c_int
    if (c_associated(serial_rng)) call c_prand_destroy(serial_rng)
    ! nstream = 0, step = 0 selects the single-stream interface (rng%state).
    serial_rng = c_prand_init(PRAND_DEFAULT_TYPE, seed, 0_c_int, 0_c_int64_t, err)
  end subroutine init_serial

  ! Ensure the serial generator exists, lazily seeding it on first use so that
  ! random_fill works even without an explicit seed() call.
  subroutine ensure_serial()
    if (.not. c_associated(serial_rng)) call init_serial(PRAND_DEFAULT_SEED)
  end subroutine ensure_serial

  ! Draw one uniform [0, 1) from the serial generator.
  function serial_draw() result(z)
    real(c_double) :: z
    type(prand_t), pointer :: rng
    procedure(prand_get_double_i), pointer :: getd
    call ensure_serial()
    call c_f_pointer(serial_rng, rng)
    call c_f_procpointer(rng%get_double, getd)
    z = getd(rng%state)
  end function serial_draw

  ! support.random.seed(s): reseed the serial generator.
  subroutine fortscript_random_seed__(s)
    integer, intent(in) :: s
    integer(c_int64_t) :: seed
    seed = int(s, c_int64_t)
    if (seed <= 0_c_int64_t) seed = PRAND_DEFAULT_SEED  ! prand needs a positive seed.
    call init_serial(seed)
  end subroutine fortscript_random_seed__

  ! support.random.random_fill(x): fill x with uniform [0, 1) values.
  subroutine fortscript_random_fill__(x)
    real(8), intent(inout) :: x(:)
    integer :: i
    call ensure_serial()
    do i = 1, size(x)
      x(i) = serial_draw()
    end do
  end subroutine fortscript_random_fill__

  ! support.random.uniform_fill(low, high, x): fill x with uniform [low, high).
  subroutine fortscript_uniform_fill__(low, high, x)
    real(8), intent(in) :: low
    real(8), intent(in) :: high
    real(8), intent(inout) :: x(:)
    integer :: i
    call ensure_serial()
    do i = 1, size(x)
      x(i) = low + (high - low) * serial_draw()
    end do
  end subroutine fortscript_uniform_fill__

  ! support.random.prand_uniform(): one serial uniform [0, 1) draw.
  function fortscript_prand_uniform__() result(z)
    real(8) :: z
    z = serial_draw()
  end function fortscript_prand_uniform__

  ! support.random.prand_seed_parallel(s): initialise a multi-stream generator
  ! with one stream per OpenMP thread, for use by prand_uniform_thread inside an
  ! @omp loop. Call once before the loop.
  subroutine fortscript_prand_seed_parallel__(s)
    integer, intent(in) :: s
    integer(c_int64_t) :: seed
    integer(c_int) :: nstream, err
    seed = int(s, c_int64_t)
    if (seed <= 0_c_int64_t) seed = PRAND_DEFAULT_SEED
    nstream = max(1_c_int, int(omp_get_max_threads(), c_int))
    err = 0_c_int
    if (c_associated(par_rng)) call c_prand_destroy(par_rng)
    par_rng = c_prand_init(PRAND_DEFAULT_TYPE, seed, nstream, PRAND_STREAM_STEP, err)
  end subroutine fortscript_prand_seed_parallel__

  ! support.random.prand_uniform_thread(): one uniform [0, 1) draw from the
  ! current OpenMP thread's stream. Safe inside an @omp parallel do because each
  ! thread touches a distinct prand stream. Lazily seeds the parallel generator
  ! if prand_seed_parallel was not called first.
  function fortscript_prand_uniform_thread__() result(z)
    real(8) :: z
    type(prand_t), pointer :: rng
    type(c_ptr), pointer :: streams(:)
    procedure(prand_get_double_i), pointer :: getd
    integer :: tid

    if (.not. c_associated(par_rng)) then
      !$omp critical (prand_par_init)
      if (.not. c_associated(par_rng)) call fortscript_prand_seed_parallel__(int(PRAND_DEFAULT_SEED))
      !$omp end critical (prand_par_init)
    end if

    call c_f_pointer(par_rng, rng)
    call c_f_procpointer(rng%get_double, getd)
    call c_f_pointer(rng%state_stream, streams, [int(rng%nstream)])
    tid = omp_get_thread_num()
    if (tid < 0) tid = 0
    if (tid >= rng%nstream) tid = mod(tid, rng%nstream)  ! Stay in range defensively.
    z = getd(streams(tid + 1))
  end function fortscript_prand_uniform_thread__

end module prand_mod

! Hand-written Fortran backing module for the geom_stl FortScript support library.
! Provides ASCII and binary STL parsers plus bounds computation.
! The FortScript transpiler lowers geom_stl_read_ascii and geom_stl_read_binary
! stubs to subroutine calls into this module.
!
! All triangles are stored as flat double-precision arrays; the caller
! supplies allocatable destinations that this module sizes and fills.

module geom_stl_read_mod
  use, intrinsic :: iso_fortran_env, only: int32, real32, real64, int8
  implicit none
  private
  public :: fortscript_geom_stl_read_ascii__
  public :: fortscript_geom_stl_read_binary__
  public :: fortscript_geom_stl_bounds__

contains

  ! Compute the axis-aligned bounding box (min, max) and centroid of a
  ! triangle mesh given the per-vertex coordinate arrays.
  subroutine fortscript_geom_stl_bounds__(n, v0x, v0y, v0z, v1x, v1y, v1z, v2x, v2y, v2z, &
                                          out_min, out_max, out_center)
    integer, intent(in) :: n
    real(8), intent(in) :: v0x(:), v0y(:), v0z(:)
    real(8), intent(in) :: v1x(:), v1y(:), v1z(:)
    real(8), intent(in) :: v2x(:), v2y(:), v2z(:)
    real(8), intent(out) :: out_min(3), out_max(3), out_center(3)
    integer :: i
    real(8) :: vx, vy, vz

    if (n <= 0) then
      out_min = 0.0d0
      out_max = 0.0d0
      out_center = 0.0d0
      return
    end if

    out_min = (/ v0x(1), v0y(1), v0z(1) /)
    out_max = out_min

    do i = 1, n
      ! Vertex 0
      vx = v0x(i); vy = v0y(i); vz = v0z(i)
      out_min(1) = min(out_min(1), vx); out_max(1) = max(out_max(1), vx)
      out_min(2) = min(out_min(2), vy); out_max(2) = max(out_max(2), vy)
      out_min(3) = min(out_min(3), vz); out_max(3) = max(out_max(3), vz)
      ! Vertex 1
      vx = v1x(i); vy = v1y(i); vz = v1z(i)
      out_min(1) = min(out_min(1), vx); out_max(1) = max(out_max(1), vx)
      out_min(2) = min(out_min(2), vy); out_max(2) = max(out_max(2), vy)
      out_min(3) = min(out_min(3), vz); out_max(3) = max(out_max(3), vz)
      ! Vertex 2
      vx = v2x(i); vy = v2y(i); vz = v2z(i)
      out_min(1) = min(out_min(1), vx); out_max(1) = max(out_max(1), vx)
      out_min(2) = min(out_min(2), vy); out_max(2) = max(out_max(2), vy)
      out_min(3) = min(out_min(3), vz); out_max(3) = max(out_max(3), vz)
    end do

    out_center = 0.5d0 * (out_min + out_max)
  end subroutine fortscript_geom_stl_bounds__

  ! Read an ASCII STL file.
  ! The caller passes allocatable destination arrays; we count triangles by
  ! scanning once, then re-scan to fill the arrays.
  subroutine fortscript_geom_stl_read_ascii__(filename, n_out, &
                                              nx, ny, nz, &
                                              v0x, v0y, v0z, &
                                              v1x, v1y, v1z, &
                                              v2x, v2y, v2z)
    character(len=*), intent(in) :: filename
    integer, intent(out) :: n_out
    real(8), allocatable, intent(out) :: nx(:), ny(:), nz(:)
    real(8), allocatable, intent(out) :: v0x(:), v0y(:), v0z(:)
    real(8), allocatable, intent(out) :: v1x(:), v1y(:), v1z(:)
    real(8), allocatable, intent(out) :: v2x(:), v2y(:), v2z(:)
    integer :: unit, ios, count, idx, vidx
    character(len=512) :: line
    character(len=32) :: tok
    real(8) :: a, b, c

    ! Pass 1: count "facet normal" occurrences.
    count = 0
    open(newunit=unit, file=trim(filename), status='old', action='read', iostat=ios)
    if (ios /= 0) then
      ! Surface the path so a wrong cwd doesn't masquerade as an empty mesh.
      write(*,'(A)') 'geom_stl_read_ascii: failed to open '//trim(filename)
      n_out = 0
      allocate(nx(0), ny(0), nz(0))
      allocate(v0x(0), v0y(0), v0z(0))
      allocate(v1x(0), v1y(0), v1z(0))
      allocate(v2x(0), v2y(0), v2z(0))
      return
    end if
    do
      read(unit, '(A)', iostat=ios) line
      if (ios /= 0) exit
      line = adjustl(line)
      if (line(1:5) == 'facet' .or. line(1:5) == 'FACET') count = count + 1
    end do
    close(unit)

    n_out = count
    allocate(nx(count), ny(count), nz(count))
    allocate(v0x(count), v0y(count), v0z(count))
    allocate(v1x(count), v1y(count), v1z(count))
    allocate(v2x(count), v2y(count), v2z(count))

    if (count == 0) return

    ! Pass 2: parse facet/vertex lines.
    open(newunit=unit, file=trim(filename), status='old', action='read', iostat=ios)
    idx = 0
    vidx = 0
    do
      read(unit, '(A)', iostat=ios) line
      if (ios /= 0) exit
      line = adjustl(line)
      if (line(1:12) == 'facet normal' .or. line(1:12) == 'FACET NORMAL') then
        ! Strip "facet normal" prefix and read three floats.
        read(line(13:), *, iostat=ios) a, b, c
        if (ios == 0) then
          idx = idx + 1
          nx(idx) = a; ny(idx) = b; nz(idx) = c
          vidx = 0
        end if
      else if (line(1:6) == 'vertex' .or. line(1:6) == 'VERTEX') then
        read(line(7:), *, iostat=ios) a, b, c
        if (ios == 0 .and. idx > 0) then
          select case (vidx)
          case (0)
            v0x(idx) = a; v0y(idx) = b; v0z(idx) = c
          case (1)
            v1x(idx) = a; v1y(idx) = b; v1z(idx) = c
          case (2)
            v2x(idx) = a; v2y(idx) = b; v2z(idx) = c
          end select
          vidx = vidx + 1
        end if
      end if
    end do
    close(unit)
  end subroutine fortscript_geom_stl_read_ascii__

  ! Read a binary STL file (80-byte header, uint32 triangle count, then
  ! 50 bytes per triangle: 12 float32s + 2-byte attribute).
  subroutine fortscript_geom_stl_read_binary__(filename, n_out, &
                                               nx, ny, nz, &
                                               v0x, v0y, v0z, &
                                               v1x, v1y, v1z, &
                                               v2x, v2y, v2z)
    character(len=*), intent(in) :: filename
    integer, intent(out) :: n_out
    real(8), allocatable, intent(out) :: nx(:), ny(:), nz(:)
    real(8), allocatable, intent(out) :: v0x(:), v0y(:), v0z(:)
    real(8), allocatable, intent(out) :: v1x(:), v1y(:), v1z(:)
    real(8), allocatable, intent(out) :: v2x(:), v2y(:), v2z(:)
    integer :: unit, ios, i
    integer(int8) :: header(80)
    integer(int32) :: ntri
    real(real32) :: tri(12)
    integer(int8) :: attr(2)

    open(newunit=unit, file=trim(filename), status='old', action='read', &
         access='stream', form='unformatted', iostat=ios)
    if (ios /= 0) then
      write(*,'(A)') 'geom_stl_read_binary: failed to open '//trim(filename)
      n_out = 0
      allocate(nx(0), ny(0), nz(0))
      allocate(v0x(0), v0y(0), v0z(0))
      allocate(v1x(0), v1y(0), v1z(0))
      allocate(v2x(0), v2y(0), v2z(0))
      return
    end if

    read(unit, iostat=ios) header  ! Skip the 80-byte header.
    if (ios /= 0) then
      close(unit)
      n_out = 0
      return
    end if
    read(unit, iostat=ios) ntri    ! uint32 triangle count.
    if (ios /= 0 .or. ntri < 0) then
      close(unit)
      n_out = 0
      return
    end if

    n_out = int(ntri)
    allocate(nx(n_out), ny(n_out), nz(n_out))
    allocate(v0x(n_out), v0y(n_out), v0z(n_out))
    allocate(v1x(n_out), v1y(n_out), v1z(n_out))
    allocate(v2x(n_out), v2y(n_out), v2z(n_out))

    do i = 1, n_out
      read(unit, iostat=ios) tri, attr
      if (ios /= 0) exit
      nx(i)  = real(tri(1), 8);  ny(i)  = real(tri(2), 8);  nz(i)  = real(tri(3), 8)
      v0x(i) = real(tri(4), 8);  v0y(i) = real(tri(5), 8);  v0z(i) = real(tri(6), 8)
      v1x(i) = real(tri(7), 8);  v1y(i) = real(tri(8), 8);  v1z(i) = real(tri(9), 8)
      v2x(i) = real(tri(10), 8); v2y(i) = real(tri(11), 8); v2z(i) = real(tri(12), 8)
    end do
    close(unit)
  end subroutine fortscript_geom_stl_read_binary__

end module geom_stl_read_mod

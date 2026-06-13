(* Plotting-related generated helper templates *)

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

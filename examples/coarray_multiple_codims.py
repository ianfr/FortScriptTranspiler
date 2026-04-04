# 2D heat diffusion distributed over a 2D coarray process grid.
# A global grid of (nrows_p * block_rows) x (ncols_p * block_cols)
# interior cells is split into rectangular blocks, one per image.
# Each image owns a local tile plus one halo cell on every side,
# exchanges north/south/east/west edge data through 2D coindices,
# and advances a 5-point stencil over its interior block.
#
# Compile and link:
#   dune exec bin/main.exe -- examples/coarray_multiple_codims.py \
#       -o coarray_multiple_codims.f90
#   caf $(echo $FFLAGS) -o coarray_multiple_codims coarray_multiple_codims.f90
# Run with exactly nrows_p * ncols_p = 4 images:
#   cafrun -np 4 ./coarray_multiple_codims

def main():
    nrows_p: int = 2          # rows in the 2D process grid
    ncols_p: int = 2          # cols in the 2D process grid (4 images total)
    block_rows: int = 1000     # interior rows owned by each image
    block_cols: int = 1000     # interior cols owned by each image
    nsteps: int = 200
    alpha: float = 0.2        # diffusivity * dt / dx^2  (< 0.25 for 2D stability)

    me: int = this_image()
    row_img: int = me / ncols_p
    col_img: int = me % ncols_p
    north_row: int = (row_img + nrows_p - 1) % nrows_p
    south_row: int = (row_img + 1) % nrows_p
    west_col: int = (col_img + ncols_p - 1) % ncols_p
    east_col: int = (col_img + 1) % ncols_p

    # Local tile with one halo cell on each face.
    # array*[float, :, :][:] declares a 2D deferred coarray with 2 codimensions:
    #   real(8), allocatable :: u(:,:)[:,:]
    # The final allocate arg supplies the extra codim extent:
    #   allocate(u(block_rows+2, block_cols+2)[nrows_p,*])
    u: array*[float, :, :][:]
    allocate(u, block_rows + 2, block_cols + 2, nrows_p)

    # Scratch tile for the stencil update.
    u_new: array[float, :, :]
    allocate(u_new, block_rows + 2, block_cols + 2)
    tile: array[float, :, :]
    allocate(tile, block_rows + 2, block_cols + 2)

    # Start cold everywhere, then seed one hot spot on a single image.
    u[0:block_rows + 2, 0:block_cols + 2] = 0.0
    u_new[0:block_rows + 2, 0:block_cols + 2] = 0.0
    tile[0:block_rows + 2, 0:block_cols + 2] = 0.0
    if row_img == nrows_p / 2:
        if col_img == ncols_p / 2:
            u[block_rows / 2 + 1, block_cols / 2 + 1] = 1000.0

    sync

    for t in range(nsteps):
        # Exchange the north and south block edges.
        for j in range(1, block_cols + 1):
            u[0, j]{north_row, col_img} = u[block_rows, j]               # north halo
            u[block_rows + 1, j]{south_row, col_img} = u[1, j]           # south halo

        # Exchange the west and east block edges.
        for i in range(1, block_rows + 1):
            u[i, 0]{row_img, west_col} = u[i, block_cols]                # west halo
            u[i, block_cols + 1]{row_img, east_col} = u[i, 1]            # east halo

        sync

        # Snapshot the coarray tile locally before the concurrent sweep.
        tile[0:block_rows + 2, 0:block_cols + 2] = u[0:block_rows + 2, 0:block_cols + 2]

        # Sweep one column at a time so the @par loop walks the contiguous dimension.
        for j in range(1, block_cols + 1):
            @par
            for i in range(1, block_rows + 1):
                # Write each output cell once from the local snapshot.
                u_new[i, j] = tile[i, j] + alpha * (                    # explicit update
                    tile[i - 1, j] + tile[i + 1, j] +                   # vertical neighbors
                    tile[i, j - 1] + tile[i, j + 1] -                   # horizontal neighbors
                    4.0 * tile[i, j]
                )

        # Copy the updated interior back into the coarray tile.
        u[1:block_rows + 1, 1:block_cols + 1] = u_new[1:block_rows + 1, 1:block_cols + 1]
        sync

        if me == 0:
            print("Iteration ", t, " of ", nsteps)

    # Gather one summary statistic from every image using 2D coindex.
    peak: array*[float, :][:]
    allocate(peak, 1, nrows_p)
    peak[0] = maxval(u[1:block_rows + 1, 1:block_cols + 1])
    sync

    if me == 0:
        for r in range(nrows_p):
            for c in range(ncols_p):
                print("Image", r, c, "peak temp =", peak[0]{r, c})

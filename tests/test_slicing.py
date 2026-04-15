# Test 1D and 2D slice reads and slice-assignment writes.
# FortScript slices: start is 0-based inclusive, stop is 0-based exclusive,
# mapped to Fortran 1-based lower:upper bounds.

def main():
    v: array[float, :]
    sub: array[float, :]
    mat: array[float, :, :]
    row: array[float, :]
    col: array[float, :]
    blk: array[float, :, :]

    v = linspace(0.0, 9.0, 10)   # [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]

    # --- 1D read slices ---

    # v[2:5] -> elements at 0-based indices 2, 3, 4
    sub = v[2:5]
    if abs(sub[0] - 2.0) > 1.0e-9:
        exit(1)
    if abs(sub[2] - 4.0) > 1.0e-9:
        exit(1)

    # v[7:] -> elements 7..9 (open-ended)
    sub = v[7:]
    if abs(sub[0] - 7.0) > 1.0e-9:
        exit(1)
    if abs(sub[2] - 9.0) > 1.0e-9:
        exit(1)

    # v[:3] -> elements 0..2
    sub = v[:3]
    if abs(sub[0]) > 1.0e-9:
        exit(1)
    if abs(sub[2] - 2.0) > 1.0e-9:
        exit(1)

    # v[::3] -> every 3rd: indices 0, 3, 6, 9
    sub = v[::3]
    if abs(sub[0]) > 1.0e-9:
        exit(1)
    if abs(sub[1] - 3.0) > 1.0e-9:
        exit(1)
    if abs(sub[3] - 9.0) > 1.0e-9:
        exit(1)

    # --- 1D write slices ---

    # v[0:3] = 99.0  -> sets indices 0, 1, 2 to 99.0
    v[0:3] = 99.0
    if abs(v[0] - 99.0) > 1.0e-9:
        exit(1)
    if abs(v[2] - 99.0) > 1.0e-9:
        exit(1)
    if abs(v[3] - 3.0) > 1.0e-9:   # index 3 must remain 3.0
        exit(1)

    # v[5:8:2] = -1.0 -> sets indices 5 and 7
    v[5:8:2] = -1.0
    if abs(v[5] - (-1.0)) > 1.0e-9:
        exit(1)
    if abs(v[7] - (-1.0)) > 1.0e-9:
        exit(1)
    if abs(v[6] - 6.0) > 1.0e-9:   # index 6 must remain 6.0
        exit(1)

    # --- 2D slices ---

    # mat = reshape([1..9], [3,3]) column-major:
    # FortScript 0-indexed: col 0=[1,2,3], col 1=[4,5,6], col 2=[7,8,9]
    mat = reshape(linspace(1.0, 9.0, 9), [3, 3])

    # mat[0, :] = Fortran row 1 = [1, 4, 7]
    row = mat[0, :]
    if abs(row[0] - 1.0) > 1.0e-9:
        exit(1)
    if abs(row[1] - 4.0) > 1.0e-9:
        exit(1)
    if abs(row[2] - 7.0) > 1.0e-9:
        exit(1)

    # mat[:, 0] = Fortran column 1 = [1, 2, 3]
    col = mat[:, 0]
    if abs(col[0] - 1.0) > 1.0e-9:
        exit(1)
    if abs(col[2] - 3.0) > 1.0e-9:
        exit(1)

    # mat[0:2, 0:2] block read -> 2x2 sub-matrix
    blk = mat[0:2, 0:2]
    if abs(blk[0, 0] - 1.0) > 1.0e-9:
        exit(1)
    if abs(blk[1, 1] - 5.0) > 1.0e-9:
        exit(1)

    # 2D write: zero out top-left 2x2 block
    mat[0:2, 0:2] = 0.0
    if abs(mat[0, 0]) > 1.0e-9:
        exit(1)
    if abs(mat[1, 1]) > 1.0e-9:
        exit(1)
    if abs(mat[2, 2] - 9.0) > 1.0e-9:   # unaffected corner
        exit(1)

    print("test_slicing: all checks passed")

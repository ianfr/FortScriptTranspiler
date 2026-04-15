# Test 2D arrays: reshape (column-major Fortran fill), matmul, transpose,
# and element access with 0-based FortScript indices.

def main():
    flat: array[float, :]
    a23: array[float, :, :]   # 2 rows x 3 cols
    a32: array[float, :, :]   # 3 rows x 2 cols
    at: array[float, :, :]    # transpose of a23
    prod: array[float, :, :]  # a23 @ a32
    sq: array[float, :, :]    # 3x3
    gram: array[float, :, :]  # sq @ sq^T

    # reshape fills column-major in Fortran:
    #   flat = [1, 2, 3, 4, 5, 6]
    #   a23(:,1)=[1,2], a23(:,2)=[3,4], a23(:,3)=[5,6]
    # FortScript 0-indexed: a23[0,0]=1, a23[1,0]=2, a23[0,1]=3 ...
    flat = linspace(1.0, 6.0, 6)
    a23 = reshape(flat, [2, 3])

    if abs(a23[0, 0] - 1.0) > 1.0e-9:
        exit(1)
    if abs(a23[1, 0] - 2.0) > 1.0e-9:
        exit(1)
    if abs(a23[0, 1] - 3.0) > 1.0e-9:
        exit(1)
    if abs(a23[1, 2] - 6.0) > 1.0e-9:
        exit(1)

    # transpose: 2x3 -> 3x2, at[i,j] = a23[j,i]
    at = transpose(a23)
    if abs(at[0, 0] - 1.0) > 1.0e-9:
        exit(1)
    if abs(at[0, 1] - 2.0) > 1.0e-9:
        exit(1)
    if abs(at[2, 0] - 5.0) > 1.0e-9:
        exit(1)
    if abs(at[2, 1] - 6.0) > 1.0e-9:
        exit(1)

    # matmul: a23 (2x3) @ a32 (3x2) -> prod (2x2)
    # a32 column-major fill: a32(:,1)=[1,2,3], a32(:,2)=[4,5,6]
    # prod(1,1) = 1*1 + 3*2 + 5*3 = 22
    # prod(2,1) = 2*1 + 4*2 + 6*3 = 28
    # prod(1,2) = 1*4 + 3*5 + 5*6 = 49
    # prod(2,2) = 2*4 + 4*5 + 6*6 = 64
    a32 = reshape(flat, [3, 2])
    prod = matmul(a23, a32)

    if abs(prod[0, 0] - 22.0) > 1.0e-9:
        exit(1)
    if abs(prod[1, 0] - 28.0) > 1.0e-9:
        exit(1)
    if abs(prod[0, 1] - 49.0) > 1.0e-9:
        exit(1)
    if abs(prod[1, 1] - 64.0) > 1.0e-9:
        exit(1)

    # Gram matrix A @ A^T: diagonal must equal sum of squared row elements.
    # sq row 0 (Fortran row 1): [1, 4, 7] -> ||row||^2 = 1+16+49 = 66
    sq = reshape(linspace(1.0, 9.0, 9), [3, 3])
    gram = matmul(sq, transpose(sq))
    if abs(gram[0, 0] - 66.0) > 1.0e-9:
        exit(1)

    print("test_array_2d: all checks passed")

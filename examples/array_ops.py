# Array operation showcase covering the builtins listed in README.md

def summarize_vector_ops():
    angles: array[float, :]  # Source vector for element-wise intrinsics
    zeros_vec: array[float, :]  # zeros()
    ones_vec: array[float, :]  # ones()
    offsets: array[int, :]  # arange()
    sines: array[float, :]  # sin()
    cosines: array[float, :]  # cos()
    tangents: array[float, :]  # tan()
    logs: array[float, :]  # log()
    exps: array[float, :]  # exp()
    magnitudes: array[float, :]  # abs() and sqrt()
    shifted: array[float, :]  # Combined vector expression
    dot_value: float = 0.0  # dot()
    sum_value: float = 0.0  # sum()
    product_value: float = 0.0  # product()
    min_value: float = 0.0  # minval()
    max_value: float = 0.0  # maxval()

    angles = linspace(0.2, 1.0, 5)
    zeros_vec = zeros(5)
    ones_vec = ones(5)
    offsets = arange(5)

    sines = sin(angles)
    cosines = cos(angles)
    tangents = tan(angles)
    logs = log(ones_vec + angles)
    exps = exp(logs)
    magnitudes = sqrt(abs(sines - cosines) + ones_vec)
    shifted = zeros_vec + ones_vec + exps

    dot_value = dot(sines, cosines)
    sum_value = sum(shifted)
    product_value = product(ones_vec + 0.1 * angles)
    min_value = minval(magnitudes)
    max_value = maxval(tangents)

    print("angles[0]:", angles[0])
    print("zeros_vec[3]:", zeros_vec[3])
    print("ones_vec[4]:", ones_vec[4])
    print("offsets[4]:", offsets[4])
    print("sin[2]:", sines[2])
    print("cos[2]:", cosines[2])
    print("tan[2]:", tangents[2])
    print("exp(log())[2]:", exps[2])
    print("sqrt(abs()) min:", min_value)
    print("dot:", dot_value)
    print("sum:", sum_value)
    print("product:", product_value)
    print("max tan:", max_value)

def summarize_matrix_ops():
    flat_a: array[float, :]  # Input for reshape()
    flat_b: array[float, :]  # Second reshape() input
    mat_a: array[float, :, :]  # reshape() result
    mat_b: array[float, :, :]  # reshape() result
    transposed: array[float, :, :]  # transpose()
    gram: array[float, :, :]  # matmul() output

    flat_a = linspace(1.0, 6.0, 6)
    flat_b = linspace(6.0, 1.0, 6)
    mat_a = reshape(flat_a, [2, 3])
    mat_b = reshape(flat_b, [3, 2])
    transposed = transpose(mat_a)
    gram = matmul(mat_a, mat_b)

    print("reshape a[1, 2]:", mat_a[1, 2])
    print("transpose a[2, 1]:", transposed[2, 1])
    print("matmul[0, 0]:", gram[0, 0])
    print("matmul[1, 1]:", gram[1, 1])

def main():
    summarize_vector_ops()
    summarize_matrix_ops()

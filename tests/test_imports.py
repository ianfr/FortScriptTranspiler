# Test the import statement using the existing linear_algebra module (axpy)
# and vector_ops module (shifted_axpy, which calls axpy transitively).

import ../examples/linear_algebra
import ../examples/vector_ops

def main():
    x: array[float, :]
    y: array[float, :]
    r1: array[float, :]
    r2: array[float, :]

    x = linspace(0.0, 3.0, 4)   # [0, 1, 2, 3]
    y = ones(4)                  # [1, 1, 1, 1]

    # axpy(alpha, x, y) = alpha*x + y = [1, 3, 5, 7]
    r1 = axpy(2.0, x, y)

    if abs(r1[0] - 1.0) > 1.0e-9:
        exit(1)
    if abs(r1[1] - 3.0) > 1.0e-9:
        exit(1)
    if abs(r1[2] - 5.0) > 1.0e-9:
        exit(1)
    if abs(r1[3] - 7.0) > 1.0e-9:
        exit(1)

    # shifted_axpy(x, y) = axpy(2.0, x, y) (transitive import)
    r2 = shifted_axpy(x, y)

    if abs(r2[0] - r1[0]) > 1.0e-9:
        exit(1)
    if abs(r2[3] - r1[3]) > 1.0e-9:
        exit(1)

    # Compose: axpy applied to its own output
    r1 = axpy(0.5, r2, y)  # [0.5*1+1, 0.5*3+1, 0.5*5+1, 0.5*7+1] = [1.5, 2.5, 3.5, 4.5]
    if abs(r1[0] - 1.5) > 1.0e-9:
        exit(1)
    if abs(r1[3] - 4.5) > 1.0e-9:
        exit(1)

    print("test_imports: all checks passed")

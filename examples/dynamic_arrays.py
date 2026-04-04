# Dynamically sized array demo

def scale_and_shift(alpha: float, x: array[float, :], shift: float) -> array[float, :]:
    y: array[float, :]  # Explicit 1D deferred shape
    y = alpha * x + shift
    return y

def pairwise_sum(a: array[float, :], b: array[float, :]) -> array[float, :]:
    out: array[float, :]  # Element-wise 1D result
    out = a + b
    return out

def build_grid(rows: int, cols: int) -> array[float, :, :]:
    flat: array[float, :]  # Source values for reshape
    grid: array[float, :, :]  # Dynamic 2D result
    flat = linspace(1.0, 6.0, rows * cols)
    grid = reshape(flat, [rows, cols])
    return grid

def offset_grid(grid: array[float, :, :], delta: float) -> array[float, :, :]:
    shifted: array[float, :, :]  # Dynamic 2D output
    shifted = grid + delta
    return shifted

def main():
    x: array[float, :]  # Long-form 1D syntax
    y: array[float, :]
    z: array[float, :]
    grid: array[float, :, :]  # Dynamic matrix
    shifted: array[float, :, :]

    x = linspace(0.0, 1.0, 8)
    y = scale_and_shift(2.0, x, 1.0)
    z = pairwise_sum(x, y)
    grid = build_grid(2, 3)
    shifted = offset_grid(grid, 10.0)

    print("z[0]:", z[0])
    print("z[7]:", z[7])
    print("grid[0, 0]:", grid[0, 0])
    print("shifted[1, 2]:", shifted[1, 2])

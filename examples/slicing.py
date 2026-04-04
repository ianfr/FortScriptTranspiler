# Array slicing demo

def centered_window(data: array[float, :]) -> array[float, :]:
    window: array[float, :]  # Slice result stays dynamic
    window = data[2:6]
    return window

def every_other(data: array[float, :]) -> array[float, :]:
    picked: array[float, :]  # Positive-step slice
    picked = data[::2]
    return picked

def extract_block(grid: array[float, :, :]) -> array[float, :, :]:
    block: array[float, :, :]  # Mixed 2D slice
    block = grid[1:3, 1:4]
    return block

def main():
    values: array[float, :]  # Source vector
    tail: array[float, :]  # Open-ended slice
    evens: array[float, :]  # Stepped slice
    window: array[float, :]  # Interior slice
    grid: array[float, :, :]  # Source matrix
    row: array[float, :]  # Mixed index and slice
    col: array[float, :]  # Mixed slice and index
    block: array[float, :, :]  # 2D slice result

    values = linspace(0.0, 7.0, 8)
    values[1:7:2] = -1.0  # Slice assignment with a step
    values[:2] = 99.0  # Slice assignment from a scalar
    tail = values[3:]
    evens = every_other(values)
    window = centered_window(values)

    grid = reshape(linspace(1.0, 16.0, 16), [4, 4])
    grid[1:3, 0:2] = 0.0  # 2D slice assignment
    row = grid[2, :]
    col = grid[:, 1]
    block = extract_block(grid)

    print("values[0]:", values[0])
    print("values[3]:", values[3])
    print("tail[0]:", tail[0])
    print("evens[2]:", evens[2])
    print("window[1]:", window[1])
    print("row[2]:", row[2])
    print("col[1]:", col[1])
    print("block[1, 1]:", block[1, 1])

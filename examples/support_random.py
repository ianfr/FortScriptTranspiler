# Demonstration of support.random serial and parallel RNG helpers.

import support.random

def main():
    n: int = 1000  # Number of serial samples.
    x: array[float, :]  # Uniform samples in [0, 1).
    y: array[float, :]  # Uniform samples in [-1, 1).
    z: array[float, :]  # Standard normal samples.
    grid: array[float, :, :]  # Stateless per-site parallel samples.
    local_x: array[float, :]  # Per-image stream sample.

    allocate(x, n)
    allocate(y, n)
    allocate(z, n)
    allocate(grid, 16, 16)
    allocate(local_x, 8)

    seed(42)  # Set the serial RNG stream.
    random_fill(x)  # Fill with uniform values.
    uniform_fill(-1.0, 1.0, y)  # Fill with scaled uniform values.
    normal_fill(z)  # Fill with standard normal values.

    @par
    for i in range(16):
        for j in range(16):
            grid[i, j] = par_uniform_3d(42, i, j, 0)  # Stateless parallel draw.

    if num_images() > 1:
        seed(image_seed(42))  # Give each image a serial stream.
        random_fill(local_x)  # Draw from the image-local stream.
        print("image", this_image(), "local first sample", local_x[0])

    histogram(z, "random_demo_normal.png", "Normal samples", "x", "count", 30)
    print("uniform mean proxy", sum(x) / n)
    print("scaled mean proxy", sum(y) / n)
    print("normal mean proxy", sum(z) / n)
    print("parallel corner sample", grid[0, 0])

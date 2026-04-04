# Import demo showing recursive import expansion

import linear_algebra
import vector_ops

def main():
    x: array[float, :]  # Input vector
    y: array[float, :]  # Offset vector
    z: array[float, :]  # Direct import result
    w: array[float, :]  # Transitive import result

    x = linspace(0.0, 1.0, 5)
    y = ones(5)
    z = axpy(3.0, x, y)
    w = shifted_axpy(x, y)

    print("z[2]:", z[2])
    print("w[2]:", w[2])

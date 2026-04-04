# Intermediate module that re-imports linear_algebra

import linear_algebra

def shifted_axpy(x: array[float, :], y: array[float, :]) -> array[float, :]:
    out: array[float, :]  # Uses the imported helper
    out = axpy(2.0, x, y)
    return out

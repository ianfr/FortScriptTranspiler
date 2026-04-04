# Basic helpers meant to be imported

def axpy(alpha: float, x: array[float, :], y: array[float, :]) -> array[float, :]:
    out: array[float, :]  # BLAS-like helper
    out = alpha * x + y
    return out

# An example of a basic helper meant to be imported
# support/linalg.py is the actual linear algebra support library 

def axpy(alpha: float, x: array[float, :], y: array[float, :]) -> array[float, :]:
    out: array[float, :]  # BLAS-like helper
    out = alpha * x + y
    return out

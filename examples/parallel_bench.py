# Parallel benchmark: Gaussian RBF kernel evaluation
# Each @par loop body contains only exp+cos -- no intermediate scalars,
# so hoisted variable declarations never race inside do concurrent.
# With -ftree-parallelize-loops=N -fopt-info-loop gfortran reports the
# hot loop as parallelized and links against libgomp.

def rbf_step(n: int, x: array[float], y: array[float]):
    # y[i] = exp(-x[i]^2) * cos(pi * x[i]) -- ~2 transcendentals per element
    @par
    for i in range(n):
        y[i] = exp(-x[i] * x[i]) * cos(x[i] * 3.14159265358979)

def l2_norm(n: int, y: array[float]) -> float:
    # Serial reduction -- contrasts with the parallel kernel above
    s: float = 0.0
    for i in range(n):
        s += y[i] * y[i]
    return sqrt(s)

def main():
    n: int = 2000000   # 16 MB per array -- large enough to amortize thread overhead
    nsteps: int = 50   # repeat to make wall-time measurable

    x: array[float] = linspace(-5.0, 5.0, n)
    y: array[float] = zeros(n)

    for step in range(nsteps):
        rbf_step(n, x, y)

    result: float = l2_norm(n, y)
    print("L2 norm:", result)

# Verify that an @par do-concurrent loop produces the same result as the
# equivalent serial loop. Compiled with PFFLAGS so do concurrent maps to
# gfortran auto-parallelized threads, then run with OMP_NUM_THREADS=2.

def main():
    n: int = 10000
    x: array[float, :] = linspace(0.0, 1.0, n)
    y_par: array[float, :] = zeros(n)
    y_ser: array[float, :] = zeros(n)
    total_par: float = 0.0
    total_ser: float = 0.0
    peak_par: float = -1.0
    peak_ser: float = -1.0
    i: int = 0

    # Parallel kernel: elementwise transform + reductions
    @par
    @reduce(add: total_par)
    @reduce(max: peak_par)
    for i in range(n):
        y_par[i] = sin(x[i]) * sin(x[i]) + cos(x[i]) * cos(x[i])
        total_par += y_par[i]
        if y_par[i] > peak_par:
            peak_par = y_par[i]

    # Serial equivalent computed sequentially
    for i in range(n):
        y_ser[i] = sin(x[i]) * sin(x[i]) + cos(x[i]) * cos(x[i])
        total_ser += y_ser[i]
        if y_ser[i] > peak_ser:
            peak_ser = y_ser[i]

    # Per-element equality: this transform is deterministic per index
    for i in range(n):
        if abs(y_par[i] - y_ser[i]) > 1.0e-12:
            exit(1)

    # Reductions: floating-point order can differ, so use a small tolerance
    if abs(total_par - total_ser) > 1.0e-9:
        exit(1)
    if abs(peak_par - peak_ser) > 1.0e-12:
        exit(1)

    # Sanity: sin^2 + cos^2 = 1 everywhere, so total ~ n and peak ~ 1
    if abs(total_par - n) > 1.0e-6:
        exit(1)
    if abs(peak_par - 1.0) > 1.0e-6:
        exit(1)

    print("test_do_concurrent_parallel: all checks passed")

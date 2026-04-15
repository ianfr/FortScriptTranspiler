def gaussian_rbf(xi: float) -> float:
    return exp(-xi * xi) * cos(xi * 3.14159265358979)

def rbf_gpu_kernel(n: int, x: array[float], y: array[float]):
    @par
    @gpu
    for i in range(n):
        y[i] = gaussian_rbf(x[i])

def rbf_cpu_kernel(n: int, x: array[float], y: array[float]):
    @par
    for i in range(n):
        y[i] = gaussian_rbf(x[i])

def l2_norm(n: int, y: array[float]) -> float:
    s: float = 0.0
    for i in range(n):
        s += y[i] * y[i]
    return sqrt(s)

def main():
    n: int = 100000
    x: array[float] = linspace(-5.0, 5.0, n)
    y_gpu: array[float] = zeros(n)
    y_cpu: array[float] = zeros(n)
    diff: float = 0.0

    rbf_gpu_kernel(n, x, y_gpu)
    rbf_cpu_kernel(n, x, y_cpu)

    diff = abs(l2_norm(n, y_gpu) - l2_norm(n, y_cpu))
    print("L2 diff:", diff)

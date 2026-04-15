def helper(x: float) -> float:
    return exp(-x * x)

def main():
    n: int = 32
    x: array[float] = linspace(-1.0, 1.0, n)
    y: array[float] = zeros(n)

    @par
    @gpu
    for i in range(n):
        y[i] = helper(x[i])

    print(y[0], y[n - 1])

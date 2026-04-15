# Test basic @par (do concurrent) loop: elementwise fill and sequential
# post-loop verification.

def main():
    n: int = 1000
    x: array[float, :] = linspace(0.0, 1.0, n)
    y: array[float, :] = zeros(n)
    z: array[float, :] = zeros(n)
    total: float = 0.0
    i: int = 0

    # Parallel elementwise: y[i] = x[i]^2
    @par
    for i in range(n):
        y[i] = x[i] * x[i]

    # Boundary values
    if abs(y[0]) > 1.0e-9:
        exit(1)
    if abs(y[n - 1] - 1.0) > 1.0e-9:
        exit(1)

    # Midpoint: x[499] ~= 499/999, y[499] = (499/999)^2 ~= 0.249
    if y[499] < 0.2 or y[499] > 0.3:
        exit(1)

    # Second @par: sin^2 + cos^2 = 1 everywhere
    @par
    for i in range(n):
        z[i] = sin(x[i]) * sin(x[i]) + cos(x[i]) * cos(x[i])

    if abs(z[0] - 1.0) > 1.0e-9:
        exit(1)
    if abs(z[500] - 1.0) > 1.0e-6:
        exit(1)
    if abs(z[n - 1] - 1.0) > 1.0e-6:
        exit(1)

    # Sequential sum of y: sum_{i=0}^{999} (i/999)^2 ~= n/3 ~= 333
    for i in range(n):
        total += y[i]
    if total < 300.0 or total > 400.0:
        exit(1)

    print("test_do_concurrent: all checks passed")

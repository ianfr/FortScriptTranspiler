# Test support.optimize.minimize_nelder_mead on a 2D quadratic bowl.
# The unique minimum is at (2, -1) with value 0.

import support.optimize

def parabola(x: array[float, :]) -> float:
    # Convex quadratic: minimum at (2, -1)
    return (x[0] - 2.0) * (x[0] - 2.0) + (x[1] + 1.0) * (x[1] + 1.0)

def main():
    x0: array[float, :] = [0.0, 0.0]   # Starting simplex anchor
    result: OptimizeResult              # Holds x, fun, nit, nfev, success, status

    result = minimize_nelder_mead(parabola, x0)

    if not result.success:
        exit(1)
    if abs(result.x[0] - 2.0) > 1.0e-4:
        exit(1)
    if abs(result.x[1] + 1.0) > 1.0e-4:
        exit(1)
    if result.fun > 1.0e-6:
        exit(1)
    if not (result.nit > 0):
        exit(1)
    if not (result.nfev > 0):
        exit(1)
    if not (result.status == 0):
        exit(1)

    print("test_optimize: all checks passed")

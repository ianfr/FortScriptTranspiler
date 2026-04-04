# support.optimize showcase for callable arguments and default bounds.

import support.optimize

def rosenbrock(x: array[float, :]) -> float:
    dx: float = 0.0  # Distance from the minimum along x.
    dy: float = 0.0  # Curved valley term.

    dx = 1.0 - x[0]
    dy = x[1] - x[0] * x[0]
    return dx * dx + 100.0 * dy * dy

def main():
    start: array[float, :] = [-1.2, 1.0]  # Classic Rosenbrock starting point.
    lower: array[float, :] = [-2.0, -1.0]  # Optional lower box bounds.
    upper: array[float, :] = [2.0, 3.0]  # Optional upper box bounds.
    unconstrained: OptimizeResult  # Uses the default empty bound vectors.
    bounded: OptimizeResult  # Exercises the optional bounds path.

    unconstrained = minimize_nelder_mead(rosenbrock, start)
    bounded = minimize_nelder_mead(rosenbrock, start, lower, upper)

    print("unconstrained success:", unconstrained.success)
    print("unconstrained nit:", unconstrained.nit)
    print("unconstrained fun:", unconstrained.fun)
    print("unconstrained x[0]:", unconstrained.x[0])
    print("unconstrained x[1]:", unconstrained.x[1])
    print("bounded success:", bounded.success)
    print("bounded nit:", bounded.nit)
    print("bounded fun:", bounded.fun)
    print("bounded x[0]:", bounded.x[0])
    print("bounded x[1]:", bounded.x[1])

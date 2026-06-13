# Test callable parameters and trailing default arguments.

def add_one(x: float) -> float:
    return x + 1.0    # Helper used as a first-class callable

def negate(x: float) -> float:
    return -x         # Second callable for the same parameter slot

def apply(f: callable[float, float], x: float) -> float:
    return f(x)       # Exercises the callable[T, TRet] parameter type

def add_with_default(x: float, y: float = 10.0) -> float:
    return x + y      # Trailing default exercised by call-site expansion

def linear(x: float, a: float = 2.0, b: float = 3.0) -> float:
    return a * x + b  # Two trailing defaults

def main():
    r: float = 0.0

    # Callable parameter dispatch
    r = apply(add_one, 4.0)
    if abs(r - 5.0) > 1.0e-9:
        exit(1)

    r = apply(negate, 7.0)
    if abs(r + 7.0) > 1.0e-9:
        exit(1)

    # Default argument used
    r = add_with_default(3.0)
    if abs(r - 13.0) > 1.0e-9:
        exit(1)

    # Default argument overridden
    r = add_with_default(3.0, 2.0)
    if abs(r - 5.0) > 1.0e-9:
        exit(1)

    # Both defaults used
    r = linear(1.0)
    if abs(r - 5.0) > 1.0e-9:
        exit(1)

    # First default overridden, second default kept
    r = linear(1.0, 4.0)
    if abs(r - 7.0) > 1.0e-9:   # 4*1 + 3 = 7
        exit(1)

    # All arguments supplied
    r = linear(1.0, 4.0, 5.0)
    if abs(r - 9.0) > 1.0e-9:
        exit(1)

    print("test_callables: all checks passed")

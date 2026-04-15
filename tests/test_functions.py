# Test user-defined functions: return values, multiple params, early return,
# and functions that call other functions.

def square(x: float) -> float:
    return x * x

def clamp(x: float, lo: float, hi: float) -> float:
    if x < lo:
        return lo
    if x > hi:
        return hi
    return x

def hypot(a: float, b: float) -> float:
    return sqrt(square(a) + square(b))  # Exercises function calling function

def sum_ints(n: int) -> int:
    total: int = 0
    for i in range(n):
        total += i      # 0+1+...+(n-1)
    return total

def sign(x: float) -> int:
    if x > 0.0:
        return 1
    if x < 0.0:
        return -1
    return 0

def main():
    r: float = 0.0
    k: int = 0

    # square
    r = square(5.0)
    if abs(r - 25.0) > 1.0e-9:
        exit(1)

    # clamp: below lower bound
    r = clamp(-3.0, 0.0, 1.0)
    if abs(r) > 1.0e-9:
        exit(1)

    # clamp: above upper bound
    r = clamp(7.0, 0.0, 1.0)
    if abs(r - 1.0) > 1.0e-9:
        exit(1)

    # clamp: within bounds (identity)
    r = clamp(0.4, 0.0, 1.0)
    if abs(r - 0.4) > 1.0e-9:
        exit(1)

    # hypotenuse 3-4-5 triangle
    r = hypot(3.0, 4.0)
    if abs(r - 5.0) > 1.0e-9:
        exit(1)

    # sum_ints: 0+1+...+9 = 45
    k = sum_ints(10)
    if not (k == 45):
        exit(1)

    # sign
    k = sign(3.5)
    if not (k == 1):
        exit(1)
    k = sign(-0.1)
    if not (k == -1):
        exit(1)
    k = sign(0.0)
    if not (k == 0):
        exit(1)

    print("test_functions: all checks passed")

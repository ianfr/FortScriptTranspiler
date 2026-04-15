# Test scalar arithmetic operators, augmented assignment, and boolean ops.

def main():
    a: int = 10
    b: int = 3
    c: float = 4.0

    # Integer arithmetic
    if not (a + b == 13):
        exit(1)
    if not (a - b == 7):
        exit(1)
    if not (a * b == 30):
        exit(1)
    if not (a % b == 1):
        exit(1)
    if not (b ** 3 == 27):
        exit(1)

    # Float arithmetic
    if abs(c * 2.5 - 10.0) > 1.0e-9:
        exit(1)
    if abs(c ** 2.0 - 16.0) > 1.0e-9:
        exit(1)
    if abs(c - 1.5 - 2.5) > 1.0e-9:
        exit(1)

    # Augmented assignment on int
    a += 5   # 15
    a -= 3   # 12
    a *= 2   # 24
    if not (a == 24):
        exit(1)

    # Augmented assignment on float
    c += 1.0   # 5.0
    c *= 3.0   # 15.0
    c /= 5.0   # 3.0
    if abs(c - 3.0) > 1.0e-9:
        exit(1)

    # Comparison operators
    if not (a > b):
        exit(1)
    if not (b < a):
        exit(1)
    if not (b >= 3):
        exit(1)
    if not (a <= 24):
        exit(1)
    if not (a != b):
        exit(1)

    # Boolean operators
    if not (True and True):
        exit(1)
    if True and False:
        exit(1)
    if not (False or True):
        exit(1)
    if not True:
        exit(1)
    if not (not False):
        exit(1)

    print("test_arithmetic: all checks passed")

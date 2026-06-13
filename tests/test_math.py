# Test scalar math builtins not exercised by test_array_1d (which covers
# array forms of sin/cos/exp/log/sqrt/abs). Adds tan in particular.

def main():
    # Trivial identities at zero
    if abs(sin(0.0)) > 1.0e-9:
        exit(1)
    if abs(cos(0.0) - 1.0) > 1.0e-9:
        exit(1)
    if abs(tan(0.0)) > 1.0e-9:
        exit(1)
    if abs(exp(0.0) - 1.0) > 1.0e-9:
        exit(1)
    if abs(log(1.0)) > 1.0e-9:
        exit(1)
    if abs(sqrt(4.0) - 2.0) > 1.0e-9:
        exit(1)
    if abs(abs(-5.0) - 5.0) > 1.0e-9:
        exit(1)

    # tan(pi/4) = 1
    if abs(tan(0.7853981633974483) - 1.0) > 1.0e-6:
        exit(1)

    # sin(pi/2) = 1, cos(pi) = -1
    if abs(sin(1.5707963267948966) - 1.0) > 1.0e-6:
        exit(1)
    if abs(cos(3.141592653589793) + 1.0) > 1.0e-6:
        exit(1)

    # exp(1) ~ 2.71828, log(e) = 1
    if abs(log(exp(1.0)) - 1.0) > 1.0e-9:
        exit(1)

    print("test_math: all checks passed")

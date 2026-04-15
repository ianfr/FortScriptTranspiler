# Test 1D array creation builtins (zeros, ones, linspace, arange) and
# elementwise math ops (sin/cos identity, exp/log inverse, sqrt, abs),
# plus reductions (sum, dot, minval, maxval, product, size).

def main():
    z: array[float, :]
    o: array[float, :]
    s: array[float, :]
    ia: array[int, :]
    trig: array[float, :]
    rnd: array[float, :]
    d: float = 0.0

    z = zeros(6)
    o = ones(6)
    s = linspace(0.0, 5.0, 6)   # [0, 1, 2, 3, 4, 5]
    ia = arange(6)               # [0, 1, 2, 3, 4, 5] (int)

    # zeros: every element is 0.0
    if abs(z[0]) > 1.0e-9:
        exit(1)
    if abs(z[5]) > 1.0e-9:
        exit(1)

    # ones: every element is 1.0
    if abs(o[0] - 1.0) > 1.0e-9:
        exit(1)
    if abs(o[5] - 1.0) > 1.0e-9:
        exit(1)

    # linspace endpoints and midpoint
    if abs(s[0]) > 1.0e-9:
        exit(1)
    if abs(s[3] - 3.0) > 1.0e-9:
        exit(1)
    if abs(s[5] - 5.0) > 1.0e-9:
        exit(1)

    # arange: integer 0-based sequence
    if not (ia[0] == 0):
        exit(1)
    if not (ia[5] == 5):
        exit(1)

    # sum: sum(ones(6)) = 6.0
    d = sum(o)
    if abs(d - 6.0) > 1.0e-9:
        exit(1)

    # dot: dot(ones, [0..5]) = 0+1+2+3+4+5 = 15
    d = dot(o, s)
    if abs(d - 15.0) > 1.0e-9:
        exit(1)

    # minval / maxval
    if abs(minval(s)) > 1.0e-9:
        exit(1)
    if abs(maxval(s) - 5.0) > 1.0e-9:
        exit(1)

    # product: (1.1)^6 ~= 1.7716; just verify it is in expected range
    d = product(o + 0.1 * o)
    if d < 1.5 or d > 2.0:
        exit(1)

    # sin^2 + cos^2 == 1 (Pythagorean identity)
    trig = sin(s) * sin(s) + cos(s) * cos(s)
    if abs(trig[0] - 1.0) > 1.0e-9:
        exit(1)
    if abs(trig[3] - 1.0) > 1.0e-6:
        exit(1)

    # exp(log(x)) == x for x > 0: use o + s = [1..6]
    rnd = exp(log(o + s))
    if abs(rnd[0] - 1.0) > 1.0e-9:
        exit(1)
    if abs(rnd[4] - 5.0) > 1.0e-6:
        exit(1)

    # sqrt(x**2) == x for x >= 0
    rnd = sqrt(s * s)
    if abs(rnd[0]) > 1.0e-9:
        exit(1)
    if abs(rnd[3] - 3.0) > 1.0e-9:
        exit(1)

    # abs on negative array
    rnd = abs(z - s)   # |0 - [0..5]| = [0,1,2,3,4,5]
    if abs(rnd[2] - 2.0) > 1.0e-9:
        exit(1)

    # size
    if not (size(s) == 6):
        exit(1)

    print("test_array_1d: all checks passed")

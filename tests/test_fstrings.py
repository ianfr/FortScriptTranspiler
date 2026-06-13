# Smoke test: f-string interpolation transpiles, compiles, and runs.
# String equality is not a language feature, so this test only verifies
# the program executes to completion with exit code 0.

def main():
    x: float = 3.14
    n: int = 8
    label: string

    # Plain scalar interpolation
    print(f"x = {x}")
    print(f"n = {n}, double = {2 * n}")

    # Expression interpolation
    print(f"2x = {2.0 * x}, x^2 = {x * x}")

    # Assignment of an f-string to a string variable
    label = f"value is {x}"
    print(label)

    # Format specifier ":.Nf" for floats
    print(f"x to 2dp: {x:.2f}")
    print(f"x to 5dp: {x:.5f}")

    # f-string inside a loop
    for i in range(3):
        print(f"i={i}, n*i={n * i}")

    print("test_fstrings: all checks passed")

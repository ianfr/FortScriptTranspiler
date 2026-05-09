# F-string interpolation demo

def main():
    x: float = 3.14
    n: int = 8
    label: string

    # Simple scalar interpolation
    print(f"x = {x}")
    print(f"n = {n}, x = {x}")

    # Expression inside interpolation
    print(f"2*x = {2.0 * x}")
    print(f"n squared = {n * n}")

    # Assigned to a string variable
    label = f"value is {x}"
    print(label)

    # Format specifier: :.Nf controls decimal places
    print(f"x to 2 dp: {x:.2f}")
    print(f"x to 5 dp: {x:.5f}")

    # Building labels inside a loop
    vals: array[float, :]
    allocate(vals, n)
    for i in range(n):
        vals[i] = x * i
        print(f"vals[{i}] = {vals[i]:.3f}")

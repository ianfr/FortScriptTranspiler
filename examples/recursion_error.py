# This should fail - recursion is not allowed in FortScript

def factorial(n: int) -> int:
    if n <= 1:
        return 1
    else:
        return n * factorial(n - 1)

def main():
    x: int = factorial(5)
    print(x)

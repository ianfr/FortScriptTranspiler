# Test the `pass` statement as a no-op placeholder in function bodies
# and inside control flow branches.

def noop():
    pass    # `pass` is the only body

def conditional_noop(flag: bool) -> int:
    if flag:
        pass    # branch with only `pass`
    else:
        return 0
    return 1

def main():
    i: int = 0

    # Calling a noop function must not affect the caller's state
    noop()

    if not (conditional_noop(True) == 1):
        exit(1)
    if not (conditional_noop(False) == 0):
        exit(1)

    # `pass` inside a loop body is a legal no-op iteration
    for i in range(5):
        pass

    print("test_pass: all checks passed")

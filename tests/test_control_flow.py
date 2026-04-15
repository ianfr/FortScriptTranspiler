# Test if/elif/else, while loops, and for loops with all range variants.

def main():
    x: int = 5
    total: int = 0
    i: int = 0

    # --- if / elif / else ---
    if x == 5:
        x = 50
    elif x == 0:
        x = -1
    else:
        x = 99
    if not (x == 50):
        exit(1)

    # Nested condition using and
    x = 7
    if x > 5 and x < 10:
        x = 1
    else:
        x = 0
    if not (x == 1):
        exit(1)

    # else branch taken
    x = 20
    if x < 10:
        x = 0
    else:
        x = 99
    if not (x == 99):
        exit(1)

    # --- while loop ---
    x = 0
    while x < 8:
        x += 1
    if not (x == 8):
        exit(1)

    # while with compound condition
    x = 100
    total = 0
    while x > 0 and total < 3:
        x -= 10
        total += 1
    if not (total == 3):
        exit(1)

    # --- for range(n) : i = 0..n-1 ---
    total = 0
    for i in range(10):
        total += i        # 0+1+...+9 = 45
    if not (total == 45):
        exit(1)

    # --- for range(start, end) : i = start..end-1 ---
    total = 0
    for i in range(1, 6):
        total += i        # 1+2+3+4+5 = 15
    if not (total == 15):
        exit(1)

    # --- for range(start, end, step) ---
    total = 0
    for i in range(0, 10, 2):
        total += i        # 0+2+4+6+8 = 20
    if not (total == 20):
        exit(1)

    # nested for loops
    total = 0
    for i in range(3):
        for x in range(3):
            total += 1    # 3*3 = 9 iterations
    if not (total == 9):
        exit(1)

    print("test_control_flow: all checks passed")

# Test @reduce, @local, and @local_init locality clauses on do concurrent.
# Uses n=5 so expected sums are exact integers.

def main():
    n: int = 5
    x: array[float, :] = linspace(0.0, 4.0, n)  # [0, 1, 2, 3, 4]
    y: array[float, :] = zeros(n)
    total: float = 0.0       # Accumulation reduction (add)
    peak: float = -1.0       # Max reduction
    scratch: float = -99.0   # LOCAL: outer value stays unchanged
    seed: float = 0.5        # LOCAL_INIT: each iter gets a copy of 0.5
    i: int = 0

    @par
    @local(scratch)
    @local_init(seed)
    @reduce(add: total)
    @reduce(max: peak)
    for i in range(n):
        scratch = x[i]           # LOCAL copy; outer scratch unchanged
        seed = seed + scratch    # LOCAL_INIT copy; outer seed unchanged
        y[i] = x[i]
        total += x[i]
        if x[i] > peak:
            peak = x[i]

    # @reduce(add: total): 0+1+2+3+4 = 10
    if abs(total - 10.0) > 1.0e-9:
        exit(1)

    # @reduce(max: peak): max(0,1,2,3,4) = 4
    if abs(peak - 4.0) > 1.0e-9:
        exit(1)

    # @local_init(seed): outer seed is untouched
    if abs(seed - 0.5) > 1.0e-9:
        exit(1)

    # @local(scratch): outer scratch is untouched
    if abs(scratch - (-99.0)) > 1.0e-9:
        exit(1)

    # y was written inside the loop and holds [0,1,2,3,4]
    if abs(y[0]) > 1.0e-9:
        exit(1)
    if abs(y[4] - 4.0) > 1.0e-9:
        exit(1)

    print("test_do_concurrent_reductions: all checks passed")

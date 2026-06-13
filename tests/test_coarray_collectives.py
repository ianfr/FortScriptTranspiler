# Test the coarray collectives: co_sum, co_min, co_max, co_broadcast, and
# co_reduce with a user-defined pure binary operator. Every image asserts
# the same post-collective value so any image's failure aborts the run.

def my_add(a: float, b: float) -> float:
    return a + b   # User-defined reduction op for co_reduce

def main():
    me: int = this_image()
    np: int = num_images()
    expected_sum: float = 0.0
    expected_max: float = 0.0

    # --- co_sum on a scalar: contribution = me+1 -> sum = np*(np+1)/2 ---
    val: float* = 0.0
    val = 1.0 * (me + 1)
    sync
    co_sum(val)
    expected_sum = 0.5 * np * (np + 1)
    if abs(val - expected_sum) > 1.0e-9:
        exit(1)

    # --- co_min: image 0 contributes the smallest value ---
    lo: float* = 0.0
    lo = 100.0 + me * 7.0
    sync
    co_min(lo)
    if abs(lo - 100.0) > 1.0e-9:
        exit(1)

    # --- co_max: the last image contributes the largest value ---
    hi: float* = 0.0
    hi = 100.0 + me * 7.0
    sync
    co_max(hi)
    expected_max = 100.0 + (np - 1) * 7.0
    if abs(hi - expected_max) > 1.0e-9:
        exit(1)

    # --- co_broadcast from image 0 ---
    msg: float* = 0.0
    if me == 0:
        msg = -3.5
    sync
    co_broadcast(msg, 0)
    if abs(msg - (-3.5)) > 1.0e-9:
        exit(1)

    # --- co_reduce with a user-defined add: must match co_sum result ---
    contribution: float* = 0.0
    contribution = 1.0 * (me + 1)
    sync
    co_reduce(contribution, my_add)
    if abs(contribution - expected_sum) > 1.0e-9:
        exit(1)

    # --- co_sum on a fixed-size array coarray: element-wise sum ---
    arr: array*[float, 3]
    arr[0] = 1.0 * (me + 1)
    arr[1] = 2.0 * (me + 1)
    arr[2] = 3.0 * (me + 1)
    sync
    co_sum(arr)
    if abs(arr[0] - expected_sum) > 1.0e-9:
        exit(1)
    if abs(arr[1] - 2.0 * expected_sum) > 1.0e-9:
        exit(1)
    if abs(arr[2] - 3.0 * expected_sum) > 1.0e-9:
        exit(1)

    if me == 0:
        print("test_coarray_collectives: all checks passed")

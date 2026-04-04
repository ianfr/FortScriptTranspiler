# Coarray collective operations demo.
# Demonstrates co_sum, co_min, co_max, co_broadcast, and co_reduce.

def my_add(a: float, b: float) -> float:
    return a + b  # User-defined reduction operator for co_reduce.

def main():
    me: int = this_image()  # 0-based image index
    np: int = num_images()  # Total image count

    # --- co_sum: sum a scalar across all images ---
    val: float* = 0.0  # Each image contributes its rank.
    val = 1.0 * (me + 1)  # Image 0 -> 1.0, image 1 -> 2.0, ...
    sync
    co_sum(val)  # After this, every image sees sum(1..np).
    if me == 0:
        print("co_sum result:", val)  # Expected: np*(np+1)/2

    # --- co_min: find the global minimum ---
    lo: float* = 0.0
    lo = 100.0 + me * 7.0  # Scattered values across images.
    sync
    co_min(lo)  # Every image sees the minimum.
    if me == 0:
        print("co_min result:", lo)  # Expected: 100.0 (from image 0)

    # --- co_max: find the global maximum ---
    hi: float* = 0.0
    hi = 100.0 + me * 7.0  # Same scattered values.
    sync
    co_max(hi)  # Every image sees the maximum.
    if me == 0:
        print("co_max result:", hi)  # Expected: 100.0 + (np-1)*7.0

    # --- co_broadcast: send a value from one image to all ---
    msg: float* = 0.0
    if me == 0:
        msg = 42.0  # Only image 0 sets the value.
    sync
    co_broadcast(msg, 0)  # Broadcast from image 0.
    if me == np - 1:
        print("co_broadcast result:", msg)  # Expected: 42.0

    # --- co_reduce: user-defined reduction with a pure function ---
    contribution: float* = 0.0
    contribution = 1.0 * (me + 1)  # Same as co_sum test.
    sync
    co_reduce(contribution, my_add)  # Should match co_sum.
    if me == 0:
        print("co_reduce result:", contribution)  # Expected: np*(np+1)/2

    # --- co_sum on an array: element-wise sum across images ---
    arr: array*[float, 3]
    arr[0] = 1.0 * (me + 1)  # Each image contributes its rank.
    arr[1] = 2.0 * (me + 1)  # Doubled rank.
    arr[2] = 3.0 * (me + 1)  # Tripled rank.
    sync
    co_sum(arr)  # Element-wise sum across all images.
    if me == 0:
        print("co_sum array:", arr[0], arr[1], arr[2])

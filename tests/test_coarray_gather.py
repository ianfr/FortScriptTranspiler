# Test remote array-coarray element access via the data[i]{img} syntax,
# using a deferred-shape coarray allocated explicitly on every image.

def main():
    me: int = this_image()
    np: int = num_images()
    n: int = 4
    i: int = 0
    p: int = 0
    val: float = 0.0

    data: array*[float, :]
    allocate(data, n)

    # Each image fills its local slice with a rank-tagged value
    for i in range(n):
        data[i] = me * 100.0 + i

    sync   # All local writes must complete before any remote read

    # Every image verifies that the data on image 0 looks right remotely
    for i in range(n):
        val = data[i]{0}
        if abs(val - i) > 1.0e-9:   # image 0 contributes 0 + i
            exit(1)

    # Image 0 additionally walks every image's data[0]
    if me == 0:
        for p in range(np):
            val = data[0]{p}
            if abs(val - p * 100.0) > 1.0e-9:
                exit(1)
        print("test_coarray_gather: all checks passed")

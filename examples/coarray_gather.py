def main():
    # Image queries lower to Fortran's this_image()/num_images().
    me: int = this_image()
    np: int = num_images()
    n: int = 8

    # Deferred-shape coarrays must be allocated explicitly.
    data: array*[float, :]
    allocate(data, n)

    for i in range(n):
        data[i] = me * 100.0 + i

    sync

    # Image 0 gathers one element from every remote image.
    if me == 0:
        for p in range(np):
            val: float = data[0]{p}
            print("Image", p, "data[0] =", val)

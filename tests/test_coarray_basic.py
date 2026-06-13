# Test basic coarray facilities: this_image, num_images, scalar coarray
# write, and remote scalar coarray read via the {img} syntax.
# Designed to run under cafrun -np 2 but works for any image count >= 1.

def main():
    me: int = this_image()
    np: int = num_images()
    val: float = 0.0
    shared: float* = 0.0

    # Image identity is in range [0, np)
    if not (np >= 1):
        exit(1)
    if me < 0 or me >= np:
        exit(1)

    # Image 0 writes a value into its scalar coarray
    if me == 0:
        shared = 42.5

    sync   # All images must see image 0's write before they read it

    # Every image reads image 0's value remotely
    val = shared{0}
    if abs(val - 42.5) > 1.0e-9:
        exit(1)

    # Only image 0 prints to avoid duplicated success lines
    if me == 0:
        print("test_coarray_basic: all checks passed")

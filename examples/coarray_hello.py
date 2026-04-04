def main():
    # Query the current image using FortScript's 0-based builtin.
    me: int = this_image()
    np: int = num_images()
    print("Hello from image", me, "of", np)

    # Scalar coarrays use the `*` suffix on the element type.
    shared: float* = 0.0

    if me == 0:
        shared = 42.0

    sync

    # Remote image access uses 0-based image ids in curly braces.
    val: float = shared{0}
    print("Image", me, "sees shared =", val)

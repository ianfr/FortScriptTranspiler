# Test struct definition, field access, nested structs, and passing structs to
# functions.

struct Vec2:
    x: float
    y: float

struct Rect:
    origin: Vec2  # Nested struct
    width: float
    height: float
    id: int

def vec2_dot(a: Vec2, b: Vec2) -> float:
    return a.x * b.x + a.y * b.y

def rect_area(r: Rect) -> float:
    return r.width * r.height

def rect_center_x(r: Rect) -> float:
    return r.origin.x + r.width * 0.5

def main():
    u: Vec2
    v: Vec2
    r: Rect
    d: float = 0.0

    # Simple struct field write and read
    u.x = 3.0
    u.y = 4.0
    if abs(u.x - 3.0) > 1.0e-9:
        exit(1)
    if abs(u.y - 4.0) > 1.0e-9:
        exit(1)

    v.x = 1.0
    v.y = 0.0

    # Struct passed to function: dot product [3,4].[1,0] = 3
    d = vec2_dot(u, v)
    if abs(d - 3.0) > 1.0e-9:
        exit(1)

    # Self-dot: |u|^2 = 3^2 + 4^2 = 25
    d = vec2_dot(u, u)
    if abs(d - 25.0) > 1.0e-9:
        exit(1)

    # Nested struct field access
    r.origin.x = 2.0
    r.origin.y = 5.0
    r.width = 10.0
    r.height = 4.0
    r.id = 42

    if abs(r.origin.x - 2.0) > 1.0e-9:
        exit(1)
    if abs(r.height - 4.0) > 1.0e-9:
        exit(1)
    if not (r.id == 42):
        exit(1)

    # Functions using nested struct fields
    d = rect_area(r)
    if abs(d - 40.0) > 1.0e-9:
        exit(1)

    d = rect_center_x(r)
    if abs(d - 7.0) > 1.0e-9:   # 2.0 + 10.0*0.5 = 7.0
        exit(1)

    # Field reassignment
    r.id = 99
    if not (r.id == 99):
        exit(1)

    print("test_structs: all checks passed")

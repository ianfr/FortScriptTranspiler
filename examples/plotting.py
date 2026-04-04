# Basic plotting demo using pyplot-fortran

def main():
    x: array[float, :]  # Shared x-axis samples
    y: array[float, :]  # First curve
    z: array[float, :]  # Second curve

    x = linspace(0.0, 6.283185307179586, 200)
    y = sin(x)
    z = cos(x)

    plot(x, y, "fortscript_sine.png", "Sine Wave", "x", "sin(x)")
    plot(x, z, "fortscript_cosine.png", "Cosine Wave")

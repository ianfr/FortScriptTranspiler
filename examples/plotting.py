# Plotting demo: line, histogram, scatter, imshow, contour, contourf

def main():
    x: array[float, :]   # Shared x-axis samples
    y: array[float, :]   # Sine curve
    z: array[float, :]   # Cosine curve
    img: array[float, :, :]  # 2-D image / heatmap data
    cx: array[float, :]  # Contour x-axis grid
    cy: array[float, :]  # Contour y-axis grid
    cz: array[float, :, :]  # Contour z values (height field)
    i: int
    j: int

    # --- Line plot ---
    x = linspace(0.0, 6.283185307179586, 200)
    y = sin(x)
    z = cos(x)
    plot(x, y, "fortscript_line.png", "Sine Wave", "x", "sin(x)")
    plot(x, z, "fortscript_cosine.png", "Cosine Wave")

    # --- Histogram: distribution of sine values ---
    histogram(y, "fortscript_hist.png", "Histogram of sin(x)", "sin(x)", "count", 20)

    # --- Scatter plot: cos vs sin ---
    scatter(y, z, "fortscript_scatter.png", "cos(x) vs sin(x)", "sin(x)", "cos(x)")

    # --- Imshow: 20x20 image where each cell equals sin(i)*cos(j) ---
    img = reshape(zeros(400), [20, 20])
    for i in range(20):
        for j in range(20):
            img[i, j] = sin(i * 0.3) * cos(j * 0.3)
    imshow(img, "fortscript_imshow.png", "sin(i)*cos(j) Heatmap")

    # --- Contour / contourf: bowl-shaped z = x^2 + y^2 over a 30x30 grid ---
    cx = linspace(-3.0, 3.0, 30)
    cy = linspace(-3.0, 3.0, 30)
    cz = reshape(zeros(900), [30, 30])
    for i in range(30):
        for j in range(30):
            cz[i, j] = cx[i] ** 2.0 + cy[j] ** 2.0
    contour(cx, cy, cz, "fortscript_contour.png", "x^2 + y^2 Contour", "x", "y")
    contourf(cx, cy, cz, "fortscript_contourf.png", "x^2 + y^2 Filled Contour", "x", "y")

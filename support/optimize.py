# FortScript optimization support library.
# This keeps Nelder-Mead in FortScript instead of a custom Fortran helper.

struct OptimizeResult:
    x: array[float, :]  # Best point found by the solver.
    fun: float  # Objective value at x.
    nit: int  # Completed simplex iterations.
    nfev: int  # Objective evaluations.
    success: bool  # True when the tolerances were met.
    status: int  # 0=success, 1=iteration limit, -1=invalid input.

def clip_to_bounds(point: array[float, :],
                   lower: array[float, :] = zeros(0),
                   upper: array[float, :] = zeros(0)) -> array[float, :]:
    clipped: array[float, :]  # Copy so clipping does not mutate the caller value.
    n: int = 0
    i: int = 0

    clipped = point
    n = size(point)

    if size(lower) == n:
        for i in range(n):
            if clipped[i] < lower[i]:
                clipped[i] = lower[i]

    if size(upper) == n:
        for i in range(n):
            if clipped[i] > upper[i]:
                clipped[i] = upper[i]

    return clipped

def order_simplex(simplex: array[float, :, :], values: array[float, :]):
    vertex_count: int = 0
    i: int = 0
    j: int = 0
    best_idx: int = 0
    tmp_point: array[float, :]  # Row swap buffer for the simplex.
    tmp_value: float = 0.0

    vertex_count = size(values)

    for i in range(vertex_count):
        best_idx = i
        for j in range(i + 1, vertex_count):
            if values[j] < values[best_idx]:
                best_idx = j

        if best_idx != i:
            tmp_point = simplex[i, :]
            simplex[i, :] = simplex[best_idx, :]
            simplex[best_idx, :] = tmp_point

            tmp_value = values[i]
            values[i] = values[best_idx]
            values[best_idx] = tmp_value

def simplex_centroid(simplex: array[float, :, :]) -> array[float, :]:
    centroid: array[float, :]  # Average of every vertex except the last row.
    last_idx: int = 0
    i: int = 0

    last_idx = size(simplex, 1) - 1
    centroid = zeros(size(simplex, 2))

    for i in range(last_idx):
        centroid += simplex[i, :]

    centroid = centroid / last_idx
    return centroid

def minimize_nelder_mead(func: callable[array[float, :], float],
                         x0: array[float, :],
                         lower: array[float, :] = zeros(0),
                         upper: array[float, :] = zeros(0)) -> OptimizeResult:
    # Match SciPy's basic Nelder-Mead controls while keeping the API small.
    alpha: float = 1.0
    gamma: float = 2.0
    rho: float = 0.5
    sigma: float = 0.5
    x_tol: float = 1.0e-8
    f_tol: float = 1.0e-8
    n: int = 0
    max_iter: int = 0
    max_eval: int = 0
    i: int = 0
    simplex: array[float, :, :]  # Simplex rows hold candidate points.
    values: array[float, :]  # Objective values aligned with simplex rows.
    centroid: array[float, :]
    best_point: array[float, :]  # Cached best vertex for shorter updates.
    worst_point: array[float, :]  # Cached worst vertex for reflection steps.
    candidate: array[float, :]  # Scratch row used during simplex updates.
    reflected: array[float, :]
    expanded: array[float, :]
    contracted: array[float, :]
    shrunk: array[float, :]
    result: OptimizeResult
    reflected_value: float = 0.0
    expanded_value: float = 0.0
    contracted_value: float = 0.0
    x_spread: float = 0.0
    f_spread: float = 0.0
    point_spread: float = 0.0
    should_shrink: bool = False

    n = size(x0)
    result.x = x0
    result.fun = 0.0
    result.nit = 0
    result.nfev = 0
    result.success = False
    result.status = -1

    if n <= 0:
        return result

    if size(lower) != 0 and size(lower) != n:
        return result

    if size(upper) != 0 and size(upper) != n:
        return result

    if size(lower) == n and size(upper) == n:
        for i in range(n):
            if lower[i] > upper[i]:
                return result

    max_iter = 200 * n
    max_eval = 200 * n
    simplex = reshape(zeros((n + 1) * n), [n + 1, n])
    values = zeros(n + 1)

    simplex[0, :] = clip_to_bounds(x0, lower, upper)
    values[0] = func(simplex[0, :])
    result.nfev += 1

    for i in range(n):
        candidate = simplex[0, :]
        if abs(candidate[i]) > 1.0e-12:
            candidate[i] = 1.05 * candidate[i]
        else:
            candidate[i] = 2.5e-4
        candidate = clip_to_bounds(candidate, lower, upper)
        simplex[i + 1, :] = candidate
        values[i + 1] = func(candidate)
        result.nfev += 1

    while result.nit < max_iter and result.nfev < max_eval:
        order_simplex(simplex, values)
        best_point = simplex[0, :]
        result.x = best_point
        result.fun = values[0]

        x_spread = 0.0
        for i in range(1, n + 1):
            point_spread = maxval(abs(simplex[i, :] - best_point))
            if point_spread > x_spread:
                x_spread = point_spread

        f_spread = maxval(abs(values - values[0]))
        if x_spread <= x_tol and f_spread <= f_tol:
            result.success = True
            result.status = 0
            return result

        centroid = simplex_centroid(simplex)
        worst_point = simplex[n, :]
        reflected = clip_to_bounds(centroid + alpha * (centroid - worst_point), lower, upper)
        reflected_value = func(reflected)
        result.nfev += 1

        if reflected_value < values[0]:
            expanded = clip_to_bounds(centroid + gamma * (reflected - centroid), lower, upper)
            expanded_value = func(expanded)
            result.nfev += 1
            if expanded_value < reflected_value:
                simplex[n, :] = expanded
                values[n] = expanded_value
            else:
                simplex[n, :] = reflected
                values[n] = reflected_value
        elif reflected_value < values[n - 1]:
            simplex[n, :] = reflected
            values[n] = reflected_value
        else:
            should_shrink = False
            if reflected_value < values[n]:
                contracted = clip_to_bounds(centroid + rho * (reflected - centroid), lower, upper)
                contracted_value = func(contracted)
                result.nfev += 1
                if contracted_value <= reflected_value:
                    simplex[n, :] = contracted
                    values[n] = contracted_value
                else:
                    should_shrink = True
            else:
                contracted = clip_to_bounds(centroid + rho * (worst_point - centroid), lower, upper)
                contracted_value = func(contracted)
                result.nfev += 1
                if contracted_value < values[n]:
                    simplex[n, :] = contracted
                    values[n] = contracted_value
                else:
                    should_shrink = True

            if should_shrink:
                best_point = simplex[0, :]
                for i in range(1, n + 1):
                    shrunk = best_point + sigma * (simplex[i, :] - best_point)
                    shrunk = clip_to_bounds(shrunk, lower, upper)
                    simplex[i, :] = shrunk
                    values[i] = func(shrunk)
                    result.nfev += 1

        result.nit += 1

    order_simplex(simplex, values)
    result.x = simplex[0, :]
    result.fun = values[0]
    result.status = 1
    return result

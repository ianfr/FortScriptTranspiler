# Demonstrates do concurrent locality clauses and reductions.
# FortScript lowers these annotations portably around a do concurrent kernel.
#
# Compile and run:
#   dune exec bin/main.exe -- examples/do_concurrent_features.py \
#       -o do_concurrent_features.f90
#   gfortran $(echo $PFFLAGS) -o do_concurrent_features do_concurrent_features.f90
#   ./do_concurrent_features

def main():
    n: int = 200000
    x: array[float] = linspace(-1.0, 1.0, n)
    y: array[float] = zeros(n)

    scratch: float = -999.0      # LOCAL scratch stays private to each iteration
    seed: float = 0.25           # LOCAL_INIT copies this starting value per iteration
    total: float = 0.0           # REDUCE(add: ...)
    peak: float = -1.0           # REDUCE(max: ...)
    all_nonneg: bool = True      # REDUCE(and: ...)

    @par
    @local(scratch)
    @local_init(seed)
    @reduce(add: total)
    @reduce(max: peak)
    @reduce(and: all_nonneg)
    for i in range(n):
        scratch = x[i] * x[i]                            # private temporary
        seed = seed + scratch                            # per-iteration initialized copy
        y[i] = seed
        total += y[i]
        if y[i] > peak:
            peak = y[i]
        if y[i] < 0.0:
            all_nonneg = False

    print("seed outside loop =", seed)                  # stays 0.25
    print("scratch outside loop =", scratch)            # stays -999.0
    print("reduced total =", total)
    print("reduced peak =", peak)
    print("all_nonneg =", all_nonneg)

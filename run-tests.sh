#!/bin/bash

# Run all test executables in out/ and tally pass/fail by exit code.
# A test passes if it exits 0; it fails if it exits non-zero (e.g. due to a
# gfortran -fcheck=all bounds error triggered by the assertion pattern).
#
# Three execution modes are selected by the binary name:
#   - test_coarray_*           run under cafrun -np 2 (OpenCoarrays launcher)
#   - test_do_concurrent_parallel  run with OMP_NUM_THREADS=2 for repeatability
#   - everything else          run directly

passed=0
failed=0

run_test() {
    local exe="$1"
    local name
    name=$(basename "$exe")
    local output
    local exit_code

    case "$name" in
        test_coarray_*)
            # Coarray tests use 2 images via OpenCoarrays' cafrun launcher.
            output=$(cafrun -np 2 "$exe" 2>&1)
            exit_code=$?
            ;;
        test_do_concurrent_parallel)
            # CPU do-concurrent parallel test: pin to 2 threads.
            output=$(OMP_NUM_THREADS=2 "$exe" 2>&1)
            exit_code=$?
            ;;
        *)
            output=$("$exe" 2>&1)
            exit_code=$?
            ;;
    esac

    if [ $exit_code -eq 0 ]; then
        echo "[PASS] $name"
        passed=$((passed + 1))
    else
        echo "[FAIL] $name  (exit $exit_code)"
        echo "$output" | sed 's/^/       /'   # Indent captured output on failure
        failed=$((failed + 1))
    fi
}

for exe in out/test_*; do
    [ -f "$exe" ] || continue
    case "$exe" in
        *.f90) continue ;;               # Generated source, not a runnable test binary.
    esac
    [ -x "$exe" ] || continue
    run_test "$exe"
done

total=$((passed + failed))
echo ""
if [ $total -eq 0 ]; then
    echo "No test executables found in out/. Run build-tests.sh first."
    exit 1
fi

echo "Results: $passed/$total passed"
[ $failed -eq 0 ]   # Exit 0 only when every test passed

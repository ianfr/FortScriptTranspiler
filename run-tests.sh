#!/bin/zsh

# Run all test executables in out/ and tally pass/fail by exit code.
# A test passes if it exits 0; it fails if it exits non-zero (e.g. due to a
# gfortran -fcheck=all bounds error triggered by the assertion pattern).

passed=0
failed=0

for exe in out/test_*; do
    [ -f "$exe" ] || continue
    case "$exe" in
        *.f90) continue ;;               # Generated source, not a runnable test binary.
    esac
    [ -x "$exe" ] || continue
    name=$(basename "$exe")
    output=$("$exe" 2>&1)
    exit_code=$?  # Avoid zsh's read-only special parameter `status`.
    if [ $exit_code -eq 0 ]; then
        echo "[PASS] $name"
        passed=$((passed + 1))
    else
        echo "[FAIL] $name  (exit $exit_code)"
        echo "$output" | sed 's/^/       /'   # Indent captured output on failure
        failed=$((failed + 1))
    fi
done

total=$((passed + failed))
echo ""
if [ $total -eq 0 ]; then
    echo "No test executables found in out/. Run build-tests.sh first."
    exit 1
fi

echo "Results: $passed/$total passed"
[ $failed -eq 0 ]   # Exit 0 only when every test passed

#!/usr/bin/env bash
# tests/run_all.sh — Entry point for running all tests

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Clean up previous results
export ARLOG_RESULTS_FILE="tests/results.log"
: > "$ARLOG_RESULTS_FILE"

echo "=== ARLOGKN TEST SUITE (STRICT MODE) ==="
echo

# Run all test scripts
total_pass=0
total_fail=0
has_failure=0

for test_script in tests/test_*.sh; do
    if bash "$test_script"; then
        true
    else
        has_failure=1
    fi
done

# Summarize results
echo
echo "=== SUMMARY ==="
while read -r total pass fail suite_name; do
    if [[ "$fail" -eq 0 ]]; then
        printf '✅ %s (%d/%d)\n' "$suite_name" "$pass" "$total"
    else
        printf '❌ %s (%d PASS, %d FAIL)\n' "$suite_name" "$pass" "$fail"
    fi
    total_pass=$((total_pass + pass))
    total_fail=$((total_fail + fail))
done < "$ARLOG_RESULTS_FILE"

echo "-------------------"
printf 'Total Tests: %d\n' $((total_pass + total_fail))
printf 'Total Pass:  %d\n' "$total_pass"
printf 'Total Fail:  %d\n' "$total_fail"

if [[ "$has_failure" -eq 1 || "$total_fail" -gt 0 ]]; then
    exit 1
else
    exit 0
fi

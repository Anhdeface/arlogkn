#!/usr/bin/env bash
# Test script for trap fix verification
# Tests the subshell isolation pattern for temp file cleanup

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "FAIL: $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

count_temp_files() {
    local count
    count=$(ls /tmp/tmp.* 2>/dev/null | wc -l) || count=0
    echo "$count" | tr -d '[:space:]'
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: Syntax check
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Test 1: Syntax Check ==="
if bash -n arch-diag.sh 2>&1; then
    pass "Syntax check passed"
else
    fail "Syntax check failed"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: Normal execution - kernel scan
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Test 2: Normal Execution (--kernel) ==="
before_count=$(count_temp_files)
./arch-diag.sh --kernel >/dev/null 2>&1 || true
after_count=$(count_temp_files)

if [[ "$before_count" -eq "$after_count" ]]; then
    pass "No temp file leaks (before=$before_count, after=$after_count)"
else
    fail "Temp file leak detected (before=$before_count, after=$after_count)"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: Caller with EXIT trap
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Test 3: Caller With EXIT Trap ==="
cat > /tmp/test_caller_trap.sh << 'EOF'
#!/usr/bin/env bash
trap 'echo "CALLER_TRAP_FIRED"' EXIT
source ./arch-diag.sh --kernel >/dev/null 2>&1
echo "SCRIPT_EXITED_CLEANLY"
EOF
chmod +x /tmp/test_caller_trap.sh

output=$(bash /tmp/test_caller_trap.sh 2>&1)
if echo "$output" | grep -q "CALLER_TRAP_FIRED" && echo "$output" | grep -q "SCRIPT_EXITED_CLEANLY"; then
    pass "Caller's EXIT trap preserved and executed"
else
    fail "Caller's EXIT trap was lost"
    echo "Output: $output"
fi
rm -f /tmp/test_caller_trap.sh
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: Multiple sequential calls
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Test 4: Multiple Sequential Calls ==="
before_count=$(count_temp_files)
for i in 1 2 3 4 5; do
    ./arch-diag.sh --kernel >/dev/null 2>&1 || true
done
after_count=$(count_temp_files)

if [[ "$before_count" -eq "$after_count" ]]; then
    pass "5 sequential calls - no temp file leaks"
else
    fail "Temp file leak after sequential calls (before=$before_count, after=$after_count)"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: --save-all export
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Test 5: Save-All Export ==="
before_count=$(count_temp_files)
./arch-diag.sh --save-all --system >/dev/null 2>&1 || true
after_count=$(count_temp_files)

# Check if export file was created
if ls ./arch-diag-logs/*/arch-log-inspector-all.txt >/dev/null 2>&1; then
    pass "Export file created successfully"
else
    fail "Export file not created"
fi

if [[ "$before_count" -eq "$after_count" ]]; then
    pass "No temp file leaks during export"
else
    fail "Temp file leak during export (before=$before_count, after=$after_count)"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: Verify no eval on trap strings (check for actual eval usage, not comments)
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Test 6: Verify No eval on Trap Strings ==="
# Look for actual eval usage with trap variables (not in comments)
if grep -n '^[^#]*eval.*\$.*trap\|^[^#]*eval.*trap' arch-diag.sh >/dev/null 2>&1; then
    fail "Found dangerous eval on trap strings"
    grep -n '^[^#]*eval.*\$.*trap\|^[^#]*eval.*trap' arch-diag.sh || true
else
    pass "No eval on trap strings found"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Test 7: Verify subshell pattern is used
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Test 7: Verify Subshell Pattern ==="
if grep -q 'Use subshell for isolated trap' arch-diag.sh; then
    pass "Subshell isolation pattern found in comments"
else
    fail "Subshell isolation pattern comment not found"
fi

# Check for subshell opening parenthesis after trap declaration
if grep -B1 "trap 'rm -f" arch-diag.sh | grep -q '('; then
    pass "Subshell opening parenthesis found before trap"
else
    fail "Subshell opening parenthesis not found"
fi

# Check for subshell closing parenthesis
if grep -A20 "trap 'rm -f" arch-diag.sh | grep -E '^\s*\)' >/dev/null; then
    pass "Subshell closing parenthesis found after trap"
else
    fail "Subshell closing parenthesis not found"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Test 8: Interrupted execution (SIGINT simulation)
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Test 8: Interrupted Execution (SIGINT) ==="
before_count=$(count_temp_files)
# Use timeout to simulate interruption
timeout 0.5 ./arch-diag.sh --save-all --system >/dev/null 2>&1 || true
sleep 0.2  # Give time for cleanup
after_count=$(count_temp_files)

if [[ "$before_count" -eq "$after_count" ]]; then
    pass "No temp file leaks after interrupted execution"
else
    fail "Temp file leak after interrupt (before=$before_count, after=$after_count)"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo "========================================"
echo "TEST SUMMARY"
echo "========================================"
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"
echo ""

if [[ "$FAIL_COUNT" -eq 0 ]]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "SOME TESTS FAILED"
    exit 1
fi

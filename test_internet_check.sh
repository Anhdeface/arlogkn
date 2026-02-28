#!/usr/bin/env bash
# Test script for check_internet() local-first connectivity check
# Tests various network scenarios and environment variable configurations

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

# ─────────────────────────────────────────────────────────────────────────────
# Helper: Extract and test check_internet function
# ─────────────────────────────────────────────────────────────────────────────

# Source the script to get the function
source_check_internet() {
    # Extract just the check_internet function and dependencies
    # We need: check_internet, INTERNET_STATUS variable
    source <(sed -n '/^check_internet()/,/^}/p' arch-diag.sh)
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
# Test 2: Default route detection (simulated)
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Test 2: Default Route Detection ==="
source_check_internet

# Check if system has default route
if ip route 2>/dev/null | grep -q '^default'; then
    # System has default route - function should return connected
    INTERNET_STATUS="unknown"
    if check_internet; then
        if [[ "$INTERNET_STATUS" == "connected" ]]; then
            pass "Default route detected, status=connected"
        else
            fail "Default route detected but status not set correctly"
        fi
    else
        fail "Default route exists but check_internet returned false"
    fi
else
    # No default route - skip this test
    echo "SKIP: No default route on this system"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: Interface operstate check
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Test 3: Interface Operstate Check ==="
source_check_internet

# Check for any non-lo interface that is UP
found_active=0
for iface in /sys/class/net/*; do
    [[ "$(basename "$iface")" == "lo" ]] && continue
    operstate="$(cat "${iface}/operstate" 2>/dev/null || echo "")"
    if [[ "$operstate" == "up" || "$operstate" == "unknown" ]]; then
        found_active=1
        break
    fi
done

if [[ "$found_active" -eq 1 ]]; then
    INTERNET_STATUS="unknown"
    if check_internet; then
        if [[ "$INTERNET_STATUS" == "connected" ]]; then
            pass "Active interface detected, status=connected"
        else
            fail "Active interface detected but status not set correctly"
        fi
    else
        fail "Active interface exists but check_internet returned false"
    fi
else
    echo "SKIP: No active non-lo interfaces on this system"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: Loopback-only system (should be disconnected)
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Test 4: Loopback-Only System ==="
# This test checks that lo interface is correctly ignored
# On most systems, lo is always up, but should not count as "connected"

# Check if only lo exists
iface_count=$(ls -1 /sys/class/net/ 2>/dev/null | wc -l)
if [[ "$iface_count" -eq 1 ]] && [[ -d /sys/class/net/lo ]]; then
    source_check_internet
    INTERNET_STATUS="unknown"
    check_internet || true
    if [[ "$INTERNET_STATUS" == "disconnected" ]]; then
        pass "Loopback-only correctly reported as disconnected"
    else
        fail "Loopback-only should be disconnected, got: $INTERNET_STATUS"
    fi
else
    echo "SKIP: System has multiple interfaces ($iface_count)"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: ARLOGKN_CHECK_EXTERNAL=0 (default - no external calls)
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Test 5: ARLOGKN_CHECK_EXTERNAL=0 (Default) ==="
source_check_internet

# Time the execution to ensure it's fast (no external calls)
start_time=$(date +%s%N)
INTERNET_STATUS="unknown"
check_internet || true
end_time=$(date +%s%N)

# Calculate duration in milliseconds
duration_ms=$(( (end_time - start_time) / 1000000 ))

if [[ "$duration_ms" -lt 1000 ]]; then
    pass "Fast execution (${duration_ms}ms < 1000ms) - no external calls"
else
    fail "Slow execution (${duration_ms}ms) - possible external calls"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: ARLOGKN_CHECK_EXTERNAL=1 with external enabled
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Test 6: ARLOGKN_CHECK_EXTERNAL=1 (External Enabled) ==="
source_check_internet

# This test only runs if external checks are explicitly enabled
# and system has network connectivity
if [[ "${ARLOGKN_RUN_EXTERNAL_TESTS:-0}" == "1" ]]; then
    export ARLOGKN_CHECK_EXTERNAL=1
    
    INTERNET_STATUS="unknown"
    if check_internet; then
        if [[ "$INTERNET_STATUS" == "connected" ]]; then
            pass "External check enabled, status=connected"
        else
            fail "External check enabled but status not set correctly"
        fi
    else
        # May fail on air-gapped systems - that's expected
        if [[ "$INTERNET_STATUS" == "disconnected" ]]; then
            pass "External check enabled, correctly reported disconnected (air-gapped)"
        else
            fail "External check failed with unexpected status: $INTERNET_STATUS"
        fi
    fi
else
    echo "SKIP: Set ARLOGKN_RUN_EXTERNAL_TESTS=1 to run external tests"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Test 7: ARLOGKN_TEST_URL custom endpoint
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Test 7: ARLOGKN_TEST_URL Custom Endpoint ==="
source_check_internet

if [[ "${ARLOGKN_RUN_EXTERNAL_TESTS:-0}" == "1" ]]; then
    export ARLOGKN_CHECK_EXTERNAL=1
    export ARLOGKN_TEST_URL="https://example.com"
    
    INTERNET_STATUS="unknown"
    if check_internet; then
        if [[ "$INTERNET_STATUS" == "connected" ]]; then
            pass "Custom endpoint test passed"
        else
            fail "Custom endpoint test - status not set correctly"
        fi
    else
        if [[ "$INTERNET_STATUS" == "disconnected" ]]; then
            pass "Custom endpoint correctly reported disconnected"
        else
            fail "Custom endpoint test failed with unexpected status: $INTERNET_STATUS"
        fi
    fi
else
    echo "SKIP: Set ARLOGKN_RUN_EXTERNAL_TESTS=1 to run external tests"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Test 8: Performance comparison (old vs new approach)
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Test 8: Performance Benchmark ==="
source_check_internet

# Time new implementation
start_time=$(date +%s%N)
INTERNET_STATUS="unknown"
check_internet || true
end_time=$(date +%s%N)
new_duration_ms=$(( (end_time - start_time) / 1000000 ))

echo "  New implementation: ${new_duration_ms}ms"

# Old implementation would take ~5000-12000ms on disconnected systems
# (2s ping timeout + 5s curl timeout + 5s curl timeout)
if [[ "$new_duration_ms" -lt 2000 ]]; then
    pass "Performance OK (${new_duration_ms}ms < 2000ms threshold)"
else
    fail "Performance issue (${new_duration_ms}ms >= 2000ms)"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Test 9: Full script integration test
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Test 9: Full Script Integration ==="
# Run the full script and check that internet status is displayed
output=$(./arch-diag.sh --system 2>&1) || true

if echo "$output" | grep -q "Internet:"; then
    if echo "$output" | grep -qE "Internet:.*(Connected|Disconnected)"; then
        pass "Full script displays internet status correctly"
    else
        fail "Internet status format incorrect"
    fi
else
    fail "Full script does not display internet status"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Test 10: No hardcoded 8.8.8.8 in executable code
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Test 10: No Hardcoded 8.8.8.8 in Code ==="
# Extract check_internet function and verify no hardcoded 8.8.8.8 in actual code
# (comments are OK, just not in executable statements)
func_content=$(sed -n '/^check_internet()/,/^}/p' arch-diag.sh)

# Remove comments and check for 8.8.8.8
code_only=$(echo "$func_content" | grep -v '^[[:space:]]*#' | grep -v '#')

if echo "$code_only" | grep -q "8\.8\.8\.8"; then
    fail "Found hardcoded 8.8.8.8 in check_internet code"
else
    pass "No hardcoded 8.8.8.8 in check_internet code (comments OK)"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Test 11: No hardcoded google.com in default path
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Test 11: No Hardcoded google.com in Default Path ==="
# The default path should not call curl at all
# google.com should only appear in the ARLOGKN_TEST_URL default value
func_content=$(sed -n '/^check_internet()/,/^}/p' arch-diag.sh)

# Count occurrences - should only be in ARLOGKN_TEST_URL default
google_count=$(echo "$func_content" | grep -c "google.com" || echo "0")
if [[ "$google_count" -le 1 ]]; then
    pass "google.com only appears in ARLOGKN_TEST_URL default ($google_count occurrence)"
else
    fail "google.com appears $google_count times (should be ≤1)"
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

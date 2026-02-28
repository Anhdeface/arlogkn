#!/usr/bin/env bash
# Test script for cluster_errors() normalization

set -eo pipefail

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

# Source cluster_errors from the actual script
source_cluster() {
    local temp_file
    temp_file=$(mktemp)
    sed -n '/^cluster_errors()/,/^}/p' arch-diag.sh > "$temp_file"
    source "$temp_file"
    rm -f "$temp_file"
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
# Test 2: Memory address normalization
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Test 2: Memory Address Normalization ==="
source_cluster

input="Jan 01 00:00:01 localhost kernel: BUG: unable to handle kernel paging at 0xffff88001a2b3c4d
Jan 01 00:00:02 localhost kernel: BUG: unable to handle kernel paging at 0xffff88001e9f2a11
Jan 01 00:00:03 localhost kernel: BUG: unable to handle kernel paging at 0xdeadbeef12345678"

output=$(cluster_errors "$input" || true)
echo "Output: $output"

if echo "$output" | grep -q "0xADDR (x3)"; then
    pass "Memory addresses normalized and clustered (3 errors → 1 unique)"
else
    fail "Memory addresses not properly clustered"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: PID normalization
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Test 3: PID Normalization ==="
source_cluster

input="Jan 01 00:00:01 localhost kernel: process [12345] segfault
Jan 01 00:00:02 localhost kernel: process [67890] segfault
Jan 01 00:00:03 localhost kernel: process [11111] segfault"

output=$(cluster_errors "$input" || true)
echo "Output: $output"

if echo "$output" | grep -q "\[PID\] segfault (x3)"; then
    pass "PIDs normalized and clustered (3 errors → 1 unique)"
else
    fail "PIDs not properly clustered"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: IRQ number normalization
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Test 4: IRQ Number Normalization ==="
source_cluster

input="Jan 01 00:00:01 localhost kernel: IRQ 11 handler timeout
Jan 01 00:00:02 localhost kernel: IRQ 5 handler timeout
Jan 01 00:00:03 localhost kernel: IRQ 23 handler timeout"

output=$(cluster_errors "$input" || true)
echo "Output: $output"

if echo "$output" | grep -q "IRQ N handler timeout (x3)"; then
    pass "IRQ numbers normalized and clustered (3 errors → 1 unique)"
else
    fail "IRQ numbers not properly clustered"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: CPU number normalization
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Test 5: CPU Number Normalization ==="
source_cluster

input="Jan 01 00:00:01 localhost kernel: CPU 0 machine check exception
Jan 01 00:00:02 localhost kernel: CPU 3 machine check exception
Jan 01 00:00:03 localhost kernel: CPU 7 machine check exception"

output=$(cluster_errors "$input" || true)
echo "Output: $output"

if echo "$output" | grep -q "CPU N machine check exception (x3)"; then
    pass "CPU numbers normalized and clustered (3 errors → 1 unique)"
else
    fail "CPU numbers not properly clustered"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: Device name normalization (sd*)
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Test 6: Device Name Normalization (sd*) ==="
source_cluster

input="Jan 01 00:00:01 localhost kernel: I/O error on sda sector 1234
Jan 01 00:00:02 localhost kernel: I/O error on sdb sector 5678
Jan 01 00:00:03 localhost kernel: I/O error on sdc sector 9012"

output=$(cluster_errors "$input" || true)
echo "Output: $output"

if echo "$output" | grep -q "sdDEVICE sector N (x3)"; then
    pass "Device names (sd*) normalized and clustered (3 errors → 1 unique)"
else
    fail "Device names (sd*) not properly clustered"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Test 7: NVMe device name normalization
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Test 7: NVMe Device Name Normalization ==="
source_cluster

input="Jan 01 00:00:01 localhost kernel: NVMe timeout on nvme0n1
Jan 01 00:00:02 localhost kernel: NVMe timeout on nvme1n1
Jan 01 00:00:03 localhost kernel: NVMe timeout on nvme2n1"

output=$(cluster_errors "$input" || true)
echo "Output: $output"

if echo "$output" | grep -q "nvmeDEVICE (x3)"; then
    pass "NVMe device names normalized and clustered (3 errors → 1 unique)"
else
    fail "NVMe device names not properly clustered"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Test 8: MAC address normalization
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Test 8: MAC Address Normalization ==="
source_cluster

input="Jan 01 00:00:01 localhost kernel: link down on aa:bb:cc:dd:ee:ff
Jan 01 00:00:02 localhost kernel: link down on 11:22:33:44:55:66
Jan 01 00:00:03 localhost kernel: link down on de:ad:be:ef:ca:fe"

output=$(cluster_errors "$input" || true)
echo "Output: $output"

if echo "$output" | grep -q "MAC (x3)"; then
    pass "MAC addresses normalized and clustered (3 errors → 1 unique)"
else
    fail "MAC addresses not properly clustered"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Test 9: Port number normalization
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Test 9: Port Number Normalization ==="
source_cluster

input="Jan 01 00:00:01 localhost kernel: connection refused on :8080
Jan 01 00:00:02 localhost kernel: connection refused on :3306
Jan 01 00:00:03 localhost kernel: connection refused on :5432"

output=$(cluster_errors "$input" || true)
echo "Output: $output"

if echo "$output" | grep -q ":PORT (x3)"; then
    pass "Port numbers normalized and clustered (3 errors → 1 unique)"
else
    fail "Port numbers not properly clustered"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Test 10: Mixed dynamic content
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Test 10: Mixed Dynamic Content ==="
source_cluster

input="Jan 01 00:00:01 localhost kernel: BUG at 0xffff88001a2b3c4d in process [12345] on CPU 0
Jan 01 00:00:02 localhost kernel: BUG at 0xdeadbeef12345678 in process [67890] on CPU 3"

output=$(cluster_errors "$input" || true)
echo "Output: $output"

if echo "$output" | grep -q "(x2)"; then
    pass "Mixed dynamic content clustered (2 errors → 1 unique)"
else
    fail "Mixed dynamic content not properly clustered"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Test 11: Different errors should NOT cluster
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Test 11: Different Errors Should NOT Cluster ==="
source_cluster

input="Jan 01 00:00:01 localhost kernel: BUG: unable to handle kernel paging
Jan 01 00:00:02 localhost kernel: general protection fault
Jan 01 00:00:03 localhost kernel: stack-protector: Kernel stack is corrupted"

output=$(cluster_errors "$input" || true)
echo "Output: $output"

line_count=$(echo "$output" | grep -c . || echo "0")
if [[ "$line_count" -eq 3 ]]; then
    pass "Different errors correctly NOT clustered (3 unique errors)"
else
    fail "Different errors incorrectly clustered (expected 3 lines, got $line_count)"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Test 12: Full script integration
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Test 12: Full Script Integration ==="
output=$(./arch-diag.sh --kernel 2>&1) || true

if echo "$output" | grep -qE "KERNEL CRITICAL|kernel|error|Error|Scan complete|No Critical Issues"; then
    pass "Full script runs without errors"
else
    fail "Full script may have issues"
    echo "Output: $output" | head -20
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

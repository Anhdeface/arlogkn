#!/usr/bin/env bash
# tests/test_smoke_scan.sh — Smoke tests for scan_* functions
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test_framework.sh"

# Create a library version of arch-diag.sh by stripping the final 'main "$@"' call
LIB_SCRIPT="$TEST_TMPDIR/arch-diag-lib.sh"
sed '/^main "\$@"/d' "$SCRIPT_UNDER_TEST" > "$LIB_SCRIPT"
source "$LIB_SCRIPT"

stub_globals

suite_begin "Smoke Tests: Scan"

test_scan_smoke() {
    local func_name="$1"
    local rc=0
    # Run in subshell, discarding stdout and stderr, looking for crashes (non-zero exit)
    ( "$func_name" ) >/dev/null 2>&1 || rc=$?
    assert_eq "${func_name} runs without crashing" "$rc" "0"
}

# ─── RUN ──────────────────────────────────────────────────────────────────────
for func in \
    scan_system_basics \
    scan_kernel_logs \
    scan_user_services \
    scan_coredumps \
    scan_pacman_logs \
    scan_temperatures \
    scan_boot_timing \
    scan_network_interfaces \
    scan_mounts \
    scan_usb_devices \
    scan_vga_info \
    scan_drivers
do
    test_scan_smoke "$func"
done

suite_end

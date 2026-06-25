#!/usr/bin/env bash
# tests/test_smoke_export.sh — Smoke tests for export_* functions
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test_framework.sh"

# Create a library version of arch-diag.sh by stripping the final 'main "$@"' call
LIB_SCRIPT="$TEST_TMPDIR/arch-diag-lib.sh"
sed '/^main "\$@"/d' "$SCRIPT_UNDER_TEST" > "$LIB_SCRIPT"
source "$LIB_SCRIPT"

stub_globals

# Ensure OUTPUT_DIR exists for export functions
export OUTPUT_DIR="$TEST_TMPDIR/arch-diag-logs-smoke"
mkdir -p "$OUTPUT_DIR"

suite_begin "Smoke Tests: Export"

test_export_smoke() {
    local func_name="$1"
    local rc=0
    ( 
        OUTPUT_DIR="$OUTPUT_DIR"
        "$func_name" 
    ) >/dev/null 2>&1 || rc=$?
    assert_eq "${func_name} runs without crashing" "$rc" "0"
}

# ─── RUN ──────────────────────────────────────────────────────────────────────
for func in \
    export_kernel_logs \
    export_user_services \
    export_coredumps \
    export_pacman_logs \
    export_mounts \
    export_usb_devices \
    export_temperatures \
    export_boot_timing \
    export_network_interfaces \
    export_vga_info \
    export_drivers \
    export_summary \
    export_all_logs
do
    test_export_smoke "$func"
done

suite_end

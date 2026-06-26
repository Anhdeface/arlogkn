#!/usr/bin/env bash
# tests/test_drivers.sh — Strict tests for driver detection (Data Layer)

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/framework.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../src/core/02-hardware.sh"

suite_begin "02-hardware.sh (Driver Sub-modules)"

# ─── get_driver_from_sys() ────────────────────────────────────────────────────
test_get_driver_valid_symlink() {
    local fake_dev="$TEST_TMPDIR/fake_card0"
    mkdir -p "$fake_dev/device"
    mkdir -p "$TEST_TMPDIR/drivers/amdgpu"
    ln -sf "$TEST_TMPDIR/drivers/amdgpu" "$fake_dev/device/driver"

    local result
    result="$(get_driver_from_sys "$fake_dev")"
    [[ "$result" == "amdgpu" ]] || { echo "Expected amdgpu, got '$result'"; exit 1; }
}
run_test "get_driver_from_sys parses valid symlink" test_get_driver_valid_symlink

test_get_driver_no_link() {
    local fake_dev="$TEST_TMPDIR/fake_card1"
    mkdir -p "$fake_dev/device"

    local result
    result="$(get_driver_from_sys "$fake_dev")"
    [[ "$result" == "" ]] || { echo "Expected empty, got '$result'"; exit 1; }
}
run_test "get_driver_from_sys handles missing symlink" test_get_driver_no_link

# ─── _detect_drivers_sysclass() ───────────────────────────────────────────────
test_detect_drivers_sysclass_format() {
    local result
    result="$(_detect_drivers_sysclass)"
    local field_count
    field_count="$(awk -F'|' '{print NF}' <<< "$result")"
    [[ "$field_count" -eq 3 ]] || { echo "Expected 3 fields, got $field_count"; exit 1; }
    
    local IFS='|'
    # shellcheck disable=SC2206
    local -a fields=($result)
    for f in "${fields[@]}"; do
        [[ -n "$f" ]] || { echo "Found empty field in sysclass result"; exit 1; }
    done
}
run_test "_detect_drivers_sysclass returns 3 populated fields" test_detect_drivers_sysclass_format

# ─── _detect_drivers_lspci() ──────────────────────────────────────────────────
test_detect_drivers_lspci_format() {
    local result
    result="$(_detect_drivers_lspci "dummy")"
    local field_count
    field_count="$(awk -F'|' '{print NF}' <<< "$result")"
    [[ "$field_count" -eq 6 ]] || { echo "Expected 6 fields, got $field_count"; exit 1; }
    
    local IFS='|'
    # shellcheck disable=SC2206
    local -a fields=($result)
    for f in "${fields[@]}"; do
        [[ "$f" == "N/A" ]] || { echo "Expected N/A for dummy input, got '$f'"; exit 1; }
    done
}
run_test "_detect_drivers_lspci returns 6 N/A fields on empty input" test_detect_drivers_lspci_format

# ─── detect_drivers() ─────────────────────────────────────────────────────────
test_detect_drivers_format() {
    _DRIVERS_CACHE=""
    local result
    result="$(detect_drivers)"
    local field_count
    field_count="$(awk -F'|' '{print NF}' <<< "$result")"
    # Should output 16 fields according to current detect_drivers logic
    [[ "$field_count" -eq 16 ]] || { echo "Expected 16 fields, got $field_count"; exit 1; }
    
    local loaded
    loaded="$(cut -d'|' -f1 <<< "$result")"
    [[ "$loaded" =~ ^[0-9]+$ ]] || { echo "First field (module count) is not numeric: $loaded"; exit 1; }
}
run_test "detect_drivers returns 16 fields and numeric count" test_detect_drivers_format

test_detect_drivers_caching() {
    _DRIVERS_CACHE=""
    local first second
    first="$(detect_drivers)"
    # Change environment somehow to ensure caching is what returns the value
    # E.g. mock lsmod to return something weird, but cache should still return first.
    mock_command lsmod 'echo "weird_module"'
    second="$(detect_drivers)"
    
    [[ "$first" == "$second" ]] || { echo "Cache mismatch: '$first' vs '$second'"; exit 1; }
}
run_test "detect_drivers uses cache on subsequent calls" test_detect_drivers_caching

suite_end

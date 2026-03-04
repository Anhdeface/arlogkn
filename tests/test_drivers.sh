#!/usr/bin/env bash
# tests/test_drivers.sh — Tests for driver detection functions
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test_framework.sh"

stub_globals
stub_logging
extract_functions get_driver_from_sys _get_lspci detect_drivers

suite_begin "Driver Detection"

# ─── get_driver_from_sys() ────────────────────────────────────────────────────
test_get_driver_valid_symlink() {
    local fake_dev="$TEST_TMPDIR/fake_card0"
    mkdir -p "$fake_dev/device"
    # Create a fake driver symlink
    mkdir -p "$TEST_TMPDIR/drivers/amdgpu"
    ln -sf "$TEST_TMPDIR/drivers/amdgpu" "$fake_dev/device/driver"

    local result
    result="$(get_driver_from_sys "$fake_dev")"
    assert_eq "get_driver_from_sys valid link" "$result" "amdgpu"
}

test_get_driver_no_link() {
    local fake_dev="$TEST_TMPDIR/fake_card1"
    mkdir -p "$fake_dev/device"
    # No driver symlink

    local result
    result="$(get_driver_from_sys "$fake_dev")"
    assert_eq "get_driver_from_sys no link → empty" "$result" ""
}

test_get_driver_no_device() {
    local fake_dev="$TEST_TMPDIR/fake_card2"
    mkdir -p "$fake_dev"
    # No device/ subdirectory at all

    local result
    result="$(get_driver_from_sys "$fake_dev")"
    assert_eq "get_driver_from_sys no device dir → empty" "$result" ""
}

# ─── detect_drivers() ─────────────────────────────────────────────────────────
test_detect_drivers_output_format() {
    _DRIVERS_CACHE=""
    local result
    result="$(detect_drivers)"

    # Output must have 16 pipe-separated fields
    local field_count
    field_count="$(echo "$result" | awk -F'|' '{print NF}')"
    assert_eq "detect_drivers has 16 fields" "$field_count" "16"
}

test_detect_drivers_caching() {
    _DRIVERS_CACHE=""
    local first second
    first="$(detect_drivers)"
    second="$(detect_drivers)"
    assert_eq "detect_drivers cached result identical" "$first" "$second"
}

test_detect_drivers_first_field_numeric() {
    _DRIVERS_CACHE=""
    local result
    result="$(detect_drivers)"
    local loaded
    loaded="$(echo "$result" | cut -d'|' -f1)"
    assert_regex "detect_drivers loaded count numeric" "$loaded" "^[0-9]+$"
}

test_detect_drivers_no_empty_fields() {
    _DRIVERS_CACHE=""
    local result
    result="$(detect_drivers)"

    # Each field should be non-empty (at least "N/A")
    local IFS='|'
    local -a fields=($result)
    local all_filled=1
    for f in "${fields[@]}"; do
        if [[ -z "$f" ]]; then
            all_filled=0
            break
        fi
    done
    assert_eq "detect_drivers no empty fields" "$all_filled" "1"
}

# ─── RUN ──────────────────────────────────────────────────────────────────────
test_get_driver_valid_symlink
test_get_driver_no_link
test_get_driver_no_device
test_detect_drivers_output_format
test_detect_drivers_caching
test_detect_drivers_first_field_numeric
test_detect_drivers_no_empty_fields

suite_end

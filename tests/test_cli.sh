#!/usr/bin/env bash
# tests/test_cli.sh — Tests for CLI argument parser
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test_framework.sh"

stub_globals
stub_logging
extract_function parse_args

# Stub show_help to avoid full output
show_help() { printf 'USAGE: arch-diag.sh [OPTIONS]\n'; }

suite_begin "CLI Argument Parser"

# Helper: reset all scan flags before each test
reset_flags() {
    SCAN_ALL=1 SCAN_KERNEL=0 SCAN_USER=0 SCAN_MOUNT=0 SCAN_USB=0
    SCAN_DRIVER=0 SCAN_VGA=0 SCAN_SYSTEM=0 SCAN_WIKI=0
    WIKI_GROUP="" BOOT_OFFSET=0 SAVE_LOGS=0 SAVE_ALL=0
}

# ─── Flag parsing ─────────────────────────────────────────────────────────────
test_parse_all() {
    reset_flags
    parse_args --all
    assert_eq "--all sets SCAN_ALL=1" "$SCAN_ALL" "1"
}

test_parse_kernel() {
    reset_flags
    parse_args --kernel
    assert_eq "--kernel sets SCAN_KERNEL=1" "$SCAN_KERNEL" "1"
    assert_eq "--kernel clears SCAN_ALL" "$SCAN_ALL" "0"
}

test_parse_user() {
    reset_flags
    parse_args --user
    assert_eq "--user sets SCAN_USER=1" "$SCAN_USER" "1"
    assert_eq "--user clears SCAN_ALL" "$SCAN_ALL" "0"
}

test_parse_mount() {
    reset_flags
    parse_args --mount
    assert_eq "--mount sets SCAN_MOUNT=1" "$SCAN_MOUNT" "1"
}

test_parse_usb() {
    reset_flags
    parse_args --usb
    assert_eq "--usb sets SCAN_USB=1" "$SCAN_USB" "1"
}

test_parse_driver() {
    reset_flags
    parse_args --driver
    assert_eq "--driver sets SCAN_DRIVER=1" "$SCAN_DRIVER" "1"
}

test_parse_vga() {
    reset_flags
    parse_args --vga
    assert_eq "--vga sets SCAN_VGA=1" "$SCAN_VGA" "1"
}

test_parse_system() {
    reset_flags
    parse_args --system
    assert_eq "--system sets SCAN_SYSTEM=1" "$SCAN_SYSTEM" "1"
}

test_parse_wiki() {
    reset_flags
    parse_args --wiki
    assert_eq "--wiki sets SCAN_WIKI=1" "$SCAN_WIKI" "1"
}

test_parse_wiki_group() {
    reset_flags
    parse_args --wiki sound
    assert_eq "--wiki sound sets WIKI_GROUP" "$WIKI_GROUP" "sound"
    assert_eq "--wiki sound sets SCAN_WIKI=1" "$SCAN_WIKI" "1"
}

test_parse_wiki_eq() {
    reset_flags
    parse_args --wiki=sound
    assert_eq "--wiki=sound sets WIKI_GROUP" "$WIKI_GROUP" "sound"
}

test_parse_wiki_group_eq() {
    reset_flags
    parse_args --wiki-group=graphics
    assert_eq "--wiki-group=graphics" "$WIKI_GROUP" "graphics"
}

test_parse_boot_space() {
    reset_flags
    parse_args --boot -1
    assert_eq "--boot -1 sets BOOT_OFFSET" "$BOOT_OFFSET" "-1"
}

test_parse_boot_eq() {
    reset_flags
    parse_args --boot=-2
    assert_eq "--boot=-2 sets BOOT_OFFSET" "$BOOT_OFFSET" "-2"
}

test_parse_boot_invalid() {
    reset_flags
    local rc=0
    (parse_args --boot=abc) 2>/dev/null || rc=$?
    assert_ne "--boot=abc dies" "$rc" "0"
}

test_parse_boot_range_over() {
    reset_flags
    local rc=0
    (parse_args --boot=-100) 2>/dev/null || rc=$?
    assert_ne "--boot=-100 out of range dies" "$rc" "0"
}

test_parse_save() {
    reset_flags
    parse_args --save
    assert_eq "--save sets SAVE_LOGS=1" "$SAVE_LOGS" "1"
}

test_parse_save_all() {
    reset_flags
    parse_args --save-all
    assert_eq "--save-all sets SAVE_ALL=1" "$SAVE_ALL" "1"
}

test_parse_unknown() {
    reset_flags
    local rc=0
    (parse_args --nonexistent) 2>/dev/null || rc=$?
    assert_ne "--nonexistent dies" "$rc" "0"
}

test_parse_combined() {
    reset_flags
    parse_args --kernel --save --boot=-1
    assert_eq "combined: SCAN_KERNEL=1" "$SCAN_KERNEL" "1"
    assert_eq "combined: SAVE_LOGS=1" "$SAVE_LOGS" "1"
    assert_eq "combined: BOOT_OFFSET=-1" "$BOOT_OFFSET" "-1"
}

# ─── --version output ─────────────────────────────────────────────────────────
test_version_output() {
    local output rc=0
    output="$(bash "$SCRIPT_UNDER_TEST" --version 2>&1)" || rc=$?
    assert_contains "version contains version string" "$output" "$VERSION"
}

# ─── --help output ────────────────────────────────────────────────────────────
test_help_output() {
    local output rc=0
    output="$(bash "$SCRIPT_UNDER_TEST" --help 2>&1)" || rc=$?
    assert_contains "help contains USAGE" "$output" "USAGE"
}

# ─── RUN ──────────────────────────────────────────────────────────────────────
test_parse_all
test_parse_kernel
test_parse_user
test_parse_mount
test_parse_usb
test_parse_driver
test_parse_vga
test_parse_system
test_parse_wiki
test_parse_wiki_group
test_parse_wiki_eq
test_parse_wiki_group_eq
test_parse_boot_space
test_parse_boot_eq
test_parse_boot_invalid
test_parse_boot_range_over
test_parse_save
test_parse_save_all
test_parse_unknown
test_parse_combined
test_version_output
test_help_output

suite_end

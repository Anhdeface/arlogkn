#!/usr/bin/env bash
# tests/test_cli.sh — Strict tests for CLI argument parsing

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/framework.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../src/core/00-header.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../src/core/01-utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../src/core/04-exports.sh"

suite_begin "04-exports.sh (CLI Arguments)"

reset_flags() {
    SCAN_ALL=1 SCAN_KERNEL=0 SCAN_USER=0 SCAN_MOUNT=0 SCAN_USB=0
    SCAN_DRIVER=0 SCAN_VGA=0 SCAN_SYSTEM=0 SCAN_WIKI=0
    WIKI_GROUP="" BOOT_OFFSET=0 SAVE_LOGS=0 SAVE_ALL=0
}

test_parse_all() {
    reset_flags
    parse_args --all
    [[ "$SCAN_ALL" == "1" ]] || { echo "SCAN_ALL should be 1"; exit 1; }
}
run_test "parse_args --all sets SCAN_ALL=1" test_parse_all

test_parse_kernel() {
    reset_flags
    parse_args --kernel
    [[ "$SCAN_KERNEL" == "1" ]] || { echo "SCAN_KERNEL should be 1"; exit 1; }
    [[ "$SCAN_ALL" == "0" ]] || { echo "SCAN_ALL should be 0"; exit 1; }
}
run_test "parse_args --kernel sets SCAN_KERNEL=1 and clears SCAN_ALL" test_parse_kernel

test_parse_user() {
    reset_flags
    parse_args --user
    [[ "$SCAN_USER" == "1" ]] || { echo "SCAN_USER should be 1"; exit 1; }
    [[ "$SCAN_ALL" == "0" ]] || { echo "SCAN_ALL should be 0"; exit 1; }
}
run_test "parse_args --user sets SCAN_USER=1" test_parse_user

test_parse_wiki_group() {
    reset_flags
    parse_args --wiki sound
    [[ "$WIKI_GROUP" == "sound" ]] || { echo "WIKI_GROUP should be sound"; exit 1; }
    [[ "$SCAN_WIKI" == "1" ]] || { echo "SCAN_WIKI should be 1"; exit 1; }
}
run_test "parse_args --wiki group sets variables" test_parse_wiki_group

test_parse_wiki_eq() {
    reset_flags
    parse_args --wiki=sound
    [[ "$WIKI_GROUP" == "sound" ]] || { echo "WIKI_GROUP should be sound"; exit 1; }
}
run_test "parse_args --wiki=group handles equals sign" test_parse_wiki_eq

test_parse_boot_space() {
    reset_flags
    parse_args --boot -1
    [[ "$BOOT_OFFSET" == "-1" ]] || { echo "BOOT_OFFSET should be -1"; exit 1; }
}
run_test "parse_args --boot -1 sets BOOT_OFFSET" test_parse_boot_space

test_parse_boot_invalid() {
    reset_flags
    if ( parse_args --boot=abc 2>/dev/null ); then
        echo "Expected failure on invalid boot offset"
        exit 1
    fi
}
run_test "parse_args dies on invalid boot offset" test_parse_boot_invalid

test_parse_save_all() {
    reset_flags
    parse_args --save-all
    [[ "$SAVE_ALL" == "1" ]] || { echo "SAVE_ALL should be 1"; exit 1; }
}
run_test "parse_args --save-all sets SAVE_ALL=1" test_parse_save_all

test_parse_unknown() {
    reset_flags
    if ( parse_args --nonexistent 2>/dev/null ); then
        echo "Expected failure on unknown flag"
        exit 1
    fi
}
run_test "parse_args dies on unknown flags" test_parse_unknown

suite_end

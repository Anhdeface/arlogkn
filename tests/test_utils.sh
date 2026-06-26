#!/usr/bin/env bash
# tests/test_utils.sh — Strict tests for utility functions

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/framework.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../src/core/01-utils.sh"

suite_begin "01-utils.sh (Strict Isolation)"

# ─── strip_ansi() ─────────────────────────────────────────────────────────────
test_strip_ansi_plain() {
    local result
    result="$(strip_ansi "hello world")"
    [[ "$result" == "hello world" ]] || { echo "Got: $result"; exit 1; }
}
run_test "strip_ansi plain text" test_strip_ansi_plain

test_strip_ansi_colors() {
    # Script colors
    C_RED="FAKERED" C_RESET="FAKERESET"
    local result
    result="$(strip_ansi "${C_RED}error${C_RESET}")"
    [[ "$result" == "error" ]] || { echo "Got: $result"; exit 1; }
}
run_test "strip_ansi removes script color vars" test_strip_ansi_colors

test_strip_ansi_raw_esc() {
    # Raw ANSI
    local input=$'\x1b[31mred\x1b[0m'
    local result
    result="$(strip_ansi "$input")"
    [[ "$result" == "red" ]] || { echo "Got: $result"; exit 1; }
}
run_test "strip_ansi removes raw ESC sequences" test_strip_ansi_raw_esc

# ─── visible_len() ────────────────────────────────────────────────────────────
test_visible_len_plain() {
    local result
    result="$(visible_len "hello")"
    [[ "$result" == "5" ]] || { echo "Got: $result"; exit 1; }
}
run_test "visible_len plain 5 chars" test_visible_len_plain

test_visible_len_colored() {
    C_RED="FAKERED" C_RESET="FAKERESET"
    local result
    result="$(visible_len "${C_RED}test${C_RESET}")"
    [[ "$result" == "4" ]] || { echo "Got: $result"; exit 1; }
}
run_test "visible_len ignores color codes" test_visible_len_colored

# ─── die() / warn() / info() ──────────────────────────────────────────────────
test_die_exits_nonzero() {
    # die must exit 1. We run it in a sub-subshell so its exit 1 doesn't kill our subshell.
    if ( die "fatal" 2>/dev/null ); then
        echo "die did not exit with error"
        exit 1
    fi
}
run_test "die() exits with non-zero code" test_die_exits_nonzero

suite_end

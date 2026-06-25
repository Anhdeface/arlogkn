#!/usr/bin/env bash
# tests/test_utils.sh — Tests for utility functions
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test_framework.sh"

stub_globals
extract_functions strip_ansi visible_len

suite_begin "Utility Functions"

# ─── die() ────────────────────────────────────────────────────────────────────
# die calls exit 1, must run in subshell
test_die_exits_nonzero() {
    local rc=0
    ( stub_globals; stub_logging; die "test error" ) 2>/dev/null || rc=$?
    assert_eq "die exits nonzero" "$rc" "1"
}

test_die_message() {
    local output
    output="$( (stub_globals; stub_logging; die "fatal crash") 2>&1 )" || true
    assert_contains "die message content" "$output" "fatal crash"
}

# ─── warn() ───────────────────────────────────────────────────────────────────
test_warn_to_stderr() {
    stub_logging
    local stderr_out
    stderr_out="$(warn "disk full" 2>&1 1>/dev/null)"
    assert_contains "warn outputs to stderr" "$stderr_out" "disk full"
}

# ─── info() ───────────────────────────────────────────────────────────────────
test_info_to_stdout() {
    stub_logging
    local stdout_out
    stdout_out="$(info "scan complete" 2>/dev/null)"
    assert_contains "info outputs to stdout" "$stdout_out" "scan complete"
}

# ─── strip_ansi() ─────────────────────────────────────────────────────────────
test_strip_ansi_plain() {
    local result
    result="$(strip_ansi "hello world")"
    assert_eq "strip_ansi plain text" "$result" "hello world"
}

test_strip_ansi_colors() {
    # Simulate colored text using script variables
    C_RED="FAKERED" C_RESET="FAKERESET"
    local input="${C_RED}error${C_RESET}"
    local result
    result="$(strip_ansi "$input")"
    assert_eq "strip_ansi removes color vars" "$result" "error"
    C_RED="" C_RESET=""
}

test_strip_ansi_raw_esc() {
    local input=$'\x1b[31mred\x1b[0m'
    local result
    result="$(strip_ansi "$input")"
    assert_eq "strip_ansi removes raw ESC" "$result" "red"
}

test_strip_ansi_empty() {
    local result
    result="$(strip_ansi "")"
    assert_eq "strip_ansi empty string" "$result" ""
}

# ─── visible_len() ────────────────────────────────────────────────────────────
test_visible_len_plain() {
    local result
    result="$(visible_len "hello")"
    assert_eq "visible_len plain 5 chars" "$result" "5"
}

test_visible_len_colored() {
    C_RED="FAKERED" C_RESET="FAKERESET"
    local input="${C_RED}test${C_RESET}"
    local result
    result="$(visible_len "$input")"
    assert_eq "visible_len colored → 4" "$result" "4"
    C_RED="" C_RESET=""
}

test_visible_len_empty() {
    local result
    result="$(visible_len "")"
    assert_eq "visible_len empty → 0" "$result" "0"
}

# ─── RUN ──────────────────────────────────────────────────────────────────────
test_die_exits_nonzero
test_die_message
test_warn_to_stderr
test_info_to_stdout
test_strip_ansi_plain
test_strip_ansi_colors
test_strip_ansi_raw_esc
test_strip_ansi_empty
test_visible_len_plain
test_visible_len_colored
test_visible_len_empty

suite_end

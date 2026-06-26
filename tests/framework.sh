#!/usr/bin/env bash
# tests/framework.sh — Strict Test Harness for arlogkn modular architecture
# Designed for data isolation and high reliability.

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIG & ISOLATION
# ─────────────────────────────────────────────────────────────────────────────
readonly TEST_TMPDIR="$(mktemp -d /tmp/arlogkn_strict_test_XXXXXX)"
export ARLOG_RESULTS_FILE="${ARLOG_RESULTS_FILE:-/tmp/arlogkn_results_$$.txt}"

# Counters
declare -g _PASS=0 _FAIL=0 _TOTAL=0 _SUITE_NAME=""

_test_cleanup() {
    rm -rf "$TEST_TMPDIR" 2>/dev/null || true
}
trap _test_cleanup EXIT INT TERM

# ─────────────────────────────────────────────────────────────────────────────
# SUITE MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────
suite_begin() {
    _SUITE_NAME="$1"
    _PASS=0
    _FAIL=0
    _TOTAL=0
    printf '\n\033[1;36m═══ %s ═══\033[0m\n' "$_SUITE_NAME"
}

suite_end() {
    printf '\n\033[1;36m─── %s Results ───\033[0m\n' "$_SUITE_NAME"
    printf 'Total: %d  |  \033[32mPASS: %d\033[0m  |  \033[31mFAIL: %d\033[0m\n' \
        "$_TOTAL" "$_PASS" "$_FAIL"

    printf '%d %d %d %s\n' "$_TOTAL" "$_PASS" "$_FAIL" "$_SUITE_NAME" >> "$ARLOG_RESULTS_FILE"

    [[ "$_FAIL" -eq 0 ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# RUNNER
# ─────────────────────────────────────────────────────────────────────────────
# Runs a test inside a strict subshell isolation layer
run_test() {
    local test_name="$1"
    local test_func="$2"
    
    # Subshell isolation
    # Do NOT put the subshell inside the 'if' condition or '||' chain, because bash disables 'set -e'
    # inside any command that is part of a condition.
    local sub_exit=0
    set +e
    ( set -euo pipefail; mock_globals; $test_func > "$TEST_TMPDIR/out.log" 2> "$TEST_TMPDIR/err.log" )
    sub_exit=$?
    set -e
    
    if [[ "$sub_exit" -eq 0 ]]; then
        _pass "$test_name"
    else
        _fail "$test_name" "Subshell exited with error ($sub_exit) or set -e trigger."
        printf "    STDOUT:\n"
        sed 's/^/      /' "$TEST_TMPDIR/out.log"
        printf "    STDERR:\n"
        sed 's/^/      /' "$TEST_TMPDIR/err.log"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# MOCKING & STUBS
# ─────────────────────────────────────────────────────────────────────────────
export MOCK_UI_LOG="$TEST_TMPDIR/mock_ui.log"

mock_globals() {
    export C_RESET="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN="" C_BOLD=""
}

mock_command() {
    local cmd_name="$1"
    local mock_code="$2"
    # Define a function to override the command safely
    eval "${cmd_name}() {
${mock_code}
}"
}

mock_ui_begin() {
    : > "$MOCK_UI_LOG"
    # Intercept all UI rendering functions to capture raw data
    tbl_begin() { printf "tbl_begin\n" >> "$MOCK_UI_LOG"; }
    tbl_row() { printf "tbl_row\t%s\n" "$*" >> "$MOCK_UI_LOG"; }
    tbl_end() { printf "tbl_end\n" >> "$MOCK_UI_LOG"; }
    draw_box_line() { printf "draw_box_line\t%s\n" "$*" >> "$MOCK_UI_LOG"; }
    print_section() { printf "print_section\t%s\n" "$*" >> "$MOCK_UI_LOG"; }
    print_info() { printf "print_info\t%s\n" "$*" >> "$MOCK_UI_LOG"; }
}

# ─────────────────────────────────────────────────────────────────────────────
# ASSERTIONS
# ─────────────────────────────────────────────────────────────────────────────
_pass() {
    _PASS=$((_PASS + 1))
    _TOTAL=$((_TOTAL + 1))
    printf '  \033[32m✓\033[0m %s\n' "$1"
}

_fail() {
    _FAIL=$((_FAIL + 1))
    _TOTAL=$((_TOTAL + 1))
    printf '  \033[31m✗\033[0m %s\n' "$1"
    [[ -n "${2:-}" ]] && printf '    → %s\n' "$2"
}

assert_eq() {
    local msg="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        _pass "$msg"
    else
        _fail "$msg" "Expected: '$expected', Got: '$actual'"
    fi
}

assert_ui_contains() {
    local msg="$1" search_string="$2"
    if grep -qF "$search_string" "$MOCK_UI_LOG" 2>/dev/null; then
        _pass "$msg"
    else
        _fail "$msg" "UI mock did not receive: '$search_string'"
    fi
}

assert_ui_not_contains() {
    local msg="$1" search_string="$2"
    if ! grep -qF "$search_string" "$MOCK_UI_LOG" 2>/dev/null; then
        _pass "$msg"
    else
        _fail "$msg" "UI mock unexpectedly received: '$search_string'"
    fi
}

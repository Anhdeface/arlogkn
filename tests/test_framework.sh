#!/usr/bin/env bash
# tests/test_framework.sh — Minimal test harness for arch-diag.sh
# Source this file in each test suite. Zero external dependencies.

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────────────────────────────────────────
readonly SCRIPT_UNDER_TEST="${SCRIPT_UNDER_TEST:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/arch-diag.sh}"
readonly TEST_TMPDIR="$(mktemp -d /tmp/arlogkn_test_XXXXXX)"
export ARLOG_RESULTS_FILE="${ARLOG_RESULTS_FILE:-/tmp/arlogkn_test_results_$$.txt}"

# Counters
declare -g _PASS=0 _FAIL=0 _TOTAL=0 _SUITE_NAME=""

# ─────────────────────────────────────────────────────────────────────────────
# CLEANUP
# ─────────────────────────────────────────────────────────────────────────────
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

    # Write machine-readable result for run_all.sh
    printf '%d %d %d %s\n' "$_TOTAL" "$_PASS" "$_FAIL" "$_SUITE_NAME" >> "$ARLOG_RESULTS_FILE"

    [[ "$_FAIL" -eq 0 ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# ASSERT FUNCTIONS
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

# assert_eq "test_name" "actual" "expected"
assert_eq() {
    if [[ "$2" == "$3" ]]; then
        _pass "$1"
    else
        _fail "$1" "expected='$3' got='$2'"
    fi
}

# assert_ne "test_name" "actual" "not_expected"
assert_ne() {
    if [[ "$2" != "$3" ]]; then
        _pass "$1"
    else
        _fail "$1" "expected NOT '$3' but got it"
    fi
}

# assert_contains "test_name" "haystack" "needle"
assert_contains() {
    if [[ "$2" == *"$3"* ]]; then
        _pass "$1"
    else
        _fail "$1" "string does not contain '$3'"
    fi
}

# assert_not_contains "test_name" "haystack" "needle"
assert_not_contains() {
    if [[ "$2" != *"$3"* ]]; then
        _pass "$1"
    else
        _fail "$1" "string should NOT contain '$3'"
    fi
}

# assert_exit_code "test_name" expected_code command [args...]
assert_exit_code() {
    local name="$1" expected="$2"
    shift 2
    local actual=0
    "$@" >/dev/null 2>&1 || actual=$?
    if [[ "$actual" -eq "$expected" ]]; then
        _pass "$name"
    else
        _fail "$name" "exit code: expected=$expected got=$actual"
    fi
}

# assert_regex "test_name" "string" "pattern"
assert_regex() {
    if [[ "$2" =~ $3 ]]; then
        _pass "$1"
    else
        _fail "$1" "'$2' does not match regex '$3'"
    fi
}

# assert_file_exists "test_name" "path"
assert_file_exists() {
    if [[ -f "$2" ]]; then
        _pass "$1"
    else
        _fail "$1" "file not found: $2"
    fi
}

# assert_numeric "test_name" "value"
assert_numeric() {
    if [[ "$2" =~ ^-?[0-9]+$ ]]; then
        _pass "$1"
    else
        _fail "$1" "'$2' is not numeric"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION EXTRACTION
# ─────────────────────────────────────────────────────────────────────────────

# Extract a bash function from arch-diag.sh by name
# Usage: extract_function "function_name"
# The function is eval'd into the current shell context
extract_function() {
    local fname="$1"
    local body
    # Try multi-line form first: func() {\n...\n}
    body="$(sed -n "/^${fname}() {$/,/^}$/p" "$SCRIPT_UNDER_TEST")"
    # Fallback: one-liner form: func() { ...; }
    if [[ -z "$body" ]]; then
        body="$(grep -m1 "^${fname}() {" "$SCRIPT_UNDER_TEST")"
    fi
    if [[ -z "$body" ]]; then
        printf 'FATAL: function "%s" not found in %s\n' "$fname" "$SCRIPT_UNDER_TEST" >&2
        return 1
    fi
    eval "$body"
}

# Extract multiple functions at once
extract_functions() {
    for fn in "$@"; do
        extract_function "$fn"
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# GLOBAL STUBS
# ─────────────────────────────────────────────────────────────────────────────

# Initialize all global variables that arch-diag.sh declares
# Call this before running any extracted function
stub_globals() {
    # Colors (disabled for test — clean output comparison)
    C_RESET="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN="" C_BOLD=""

    # Scan scope
    SCAN_KERNEL=0 SCAN_USER=0 SCAN_ALL=1 SCAN_MOUNT=0 SCAN_USB=0
    SCAN_DRIVER=0 SCAN_VGA=0 SCAN_SYSTEM=0 SCAN_WIKI=0
    WIKI_GROUP="" BOOT_OFFSET=0 SAVE_LOGS=0 SAVE_ALL=0
    INTERNET_STATUS="unknown"

    # Output
    OUTPUT_DIR="./arch-diag-logs"

    # System info
    DISTRO_NAME="Unknown" DISTRO_TYPE="Generic"
    KERNEL_VER="" CPU_GOVERNOR="unknown" GPU_INFO="" DISPLAY_INFO=""

    # Caches
    _DRIVERS_CACHE="" _LSPCI_CACHE="" _LSPCI_CACHE_INIT=0
    _LSPCI_KNN_CACHE="" _LSPCI_KNN_CACHE_INIT=0

    # Table state
    _TBL_WIDTH=0
    _TBL_COLS=()

    # Script identity (bypass if already readonly, like in smoke tests)
    [[ "$(declare -p VERSION 2>/dev/null)" == *" -r "* ]] || VERSION="1.0.5"
    [[ "$(declare -p SCRIPT_NAME 2>/dev/null)" == *" -r "* ]] || SCRIPT_NAME="arch-diag.sh"
}

# ─────────────────────────────────────────────────────────────────────────────
# COMMON STUBS for functions that call other functions
# ─────────────────────────────────────────────────────────────────────────────

# Stub warn/info/die so extracted functions can call them
stub_logging() {
    warn() { printf '[WARN] %s\n' "$1" >&2; }
    info() { printf '[INFO] %s\n' "$1"; }
    die()  { printf '[ERROR] %s\n' "$1" >&2; exit 1; }
}

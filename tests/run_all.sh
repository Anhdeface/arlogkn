#!/usr/bin/env bash
# tests/run_all.sh — Run ShellCheck + all unit test suites
# Exit non-zero if ANY check fails (CI gate compatible)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_UNDER_TEST="$PROJECT_DIR/arch-diag.sh"

# Colors
C_BOLD=$'\033[1m' C_RESET=$'\033[0m'
C_GREEN=$'\033[32m' C_RED=$'\033[31m' C_CYAN=$'\033[1;36m' C_YELLOW=$'\033[33m'

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_TESTS=0
SUITE_RESULTS=()
OVERALL_RC=0

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1: SHELLCHECK
# ─────────────────────────────────────────────────────────────────────────────
printf '\n%s══════════════════════════════════════════════════%s\n' "$C_CYAN" "$C_RESET"
printf '%s PHASE 1: ShellCheck Static Analysis%s\n' "$C_BOLD" "$C_RESET"
printf '%s══════════════════════════════════════════════════%s\n\n' "$C_CYAN" "$C_RESET"

if command -v shellcheck &>/dev/null; then
    shellcheck_rc=0
    # Run with severity=warning, exclude informational notes
    # SC2034: unused variables (globals used by other functions)
    # SC2155: declare and assign separately (style preference)
    # SC1090: Can't follow sourced files (expected for dynamic sources)
    # SC1091: Not following sourced file (expected for test framework)
    shellcheck -S warning \
        -e SC2034 -e SC2155 -e SC1090 -e SC1091 \
        "$SCRIPT_UNDER_TEST" 2>&1 || shellcheck_rc=$?

    if [[ "$shellcheck_rc" -eq 0 ]]; then
        printf '\n  %s✓ ShellCheck: PASSED%s\n' "$C_GREEN" "$C_RESET"
    else
        printf '\n  %s✗ ShellCheck: FAILED (exit code %d)%s\n' "$C_RED" "$shellcheck_rc" "$C_RESET"
        OVERALL_RC=1
    fi
else
    printf '  %s⚠ ShellCheck not installed, skipping%s\n' "$C_YELLOW" "$C_RESET"
    printf '  Install: sudo pacman -S shellcheck\n'
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2: UNIT TESTS
# ─────────────────────────────────────────────────────────────────────────────
printf '\n%s══════════════════════════════════════════════════%s\n' "$C_CYAN" "$C_RESET"
printf '%s PHASE 2: Unit Tests%s\n' "$C_BOLD" "$C_RESET"
printf '%s══════════════════════════════════════════════════%s\n' "$C_CYAN" "$C_RESET"

# Test suites in execution order (dependencies first)
SUITES=(
    test_utils.sh
    test_detection.sh
    test_drivers.sh
    test_ui.sh
    test_tables.sh
    test_log_parsing.sh
    test_wiki.sh
    test_cli.sh
    test_export.sh
)

for suite in "${SUITES[@]}"; do
    suite_path="$SCRIPT_DIR/$suite"

    if [[ ! -f "$suite_path" ]]; then
        printf '  %s⚠ Suite not found: %s%s\n' "$C_YELLOW" "$suite" "$C_RESET"
        continue
    fi

    suite_rc=0
    bash "$suite_path" || suite_rc=$?

    if [[ "$suite_rc" -ne 0 ]]; then
        OVERALL_RC=1
        SUITE_RESULTS+=("${C_RED}✗${C_RESET} $suite")
    else
        SUITE_RESULTS+=("${C_GREEN}✓${C_RESET} $suite")
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
printf '\n%s══════════════════════════════════════════════════%s\n' "$C_CYAN" "$C_RESET"
printf '%s SUMMARY%s\n' "$C_BOLD" "$C_RESET"
printf '%s══════════════════════════════════════════════════%s\n\n' "$C_CYAN" "$C_RESET"

for sr in "${SUITE_RESULTS[@]}"; do
    printf '  %s\n' "$sr"
done

printf '\n'

if [[ "$OVERALL_RC" -eq 0 ]]; then
    printf '  %s══ ALL CHECKS PASSED ══%s\n\n' "$C_GREEN" "$C_RESET"
else
    printf '  %s══ SOME CHECKS FAILED ══%s\n\n' "$C_RED" "$C_RESET"
fi

exit "$OVERALL_RC"

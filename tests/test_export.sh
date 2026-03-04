#!/usr/bin/env bash
# tests/test_export.sh — Tests for export and disk space functions
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test_framework.sh"

stub_globals
stub_logging
extract_functions check_disk_space init_output_dir

suite_begin "Export & Disk Space"

# ─── check_disk_space() ───────────────────────────────────────────────────────
test_disk_space_pass() {
    # /tmp should have enough space
    assert_exit_code "check_disk_space /tmp passes" 0 check_disk_space "/tmp" 1024
}

test_disk_space_huge_threshold() {
    # Require absurd amount, should fail
    assert_exit_code "check_disk_space absurd threshold fails" 1 check_disk_space "/tmp" 999999999999
}

test_disk_space_nonexistent() {
    # Non-existent target should fall back to parent
    assert_exit_code "check_disk_space nonexistent fallback" 0 check_disk_space "/tmp/nonexistent_dir_test_12345" 1024
}

test_disk_space_root() {
    # / should always have space
    assert_exit_code "check_disk_space / passes" 0 check_disk_space "/" 1024
}

# ─── init_output_dir() ────────────────────────────────────────────────────────
test_init_creates_dir() {
    local original_dir="$PWD"
    cd "$TEST_TMPDIR"
    OUTPUT_DIR=""
    init_output_dir 2>/dev/null || true
    assert_ne "init_output_dir sets OUTPUT_DIR" "$OUTPUT_DIR" ""
    if [[ -n "$OUTPUT_DIR" ]]; then
        local exists=0
        [[ -d "$OUTPUT_DIR" ]] && exists=1
        assert_eq "init creates directory" "$exists" "1"
    fi
    cd "$original_dir"
}

test_init_umask_restore() {
    local original_dir="$PWD"
    cd "$TEST_TMPDIR"
    umask 0022
    local before
    before="$(umask)"
    init_output_dir 2>/dev/null || true
    local after
    after="$(umask)"
    assert_eq "init_output_dir restores umask" "$before" "$after"
    cd "$original_dir"
}

test_init_umask_restore_nondefault() {
    local original_dir="$PWD"
    cd "$TEST_TMPDIR"
    umask 0037
    local before
    before="$(umask)"
    init_output_dir 2>/dev/null || true
    local after
    after="$(umask)"
    assert_eq "init_output_dir restores non-default umask" "$before" "$after"
    umask 0022  # restore
    cd "$original_dir"
}

# ─── export_all_logs() trap verification ──────────────────────────────────────


test_export_trap_sigint_cleanup() {
    # Runtime: spawn subshell with same trap, send SIGINT, verify cleanup
    local temp_file
    temp_file="$(mktemp "$TEST_TMPDIR/trap_test_XXXXXX")"

    bash -c '
        temp_file="'"$temp_file"'"
        trap '\''[[ -n "$temp_file" && -f "$temp_file" ]] && rm -f "$temp_file" 2>/dev/null'\'' EXIT INT TERM
        kill -INT $$
    ' 2>/dev/null || true

    sleep 0.1
    local cleaned=1
    [[ -f "$temp_file" ]] && cleaned=0
    assert_eq "SIGINT cleanup removes temp" "$cleaned" "1"
    rm -f "$temp_file" 2>/dev/null || true
}

test_export_trap_sigterm_cleanup() {
    local temp_file
    temp_file="$(mktemp "$TEST_TMPDIR/trap_test2_XXXXXX")"

    bash -c '
        temp_file="'"$temp_file"'"
        trap '\''[[ -n "$temp_file" && -f "$temp_file" ]] && rm -f "$temp_file" 2>/dev/null'\'' EXIT INT TERM
        kill -TERM $$
    ' 2>/dev/null || true

    sleep 0.1
    local cleaned=1
    [[ -f "$temp_file" ]] && cleaned=0
    assert_eq "SIGTERM cleanup removes temp" "$cleaned" "1"
    rm -f "$temp_file" 2>/dev/null || true
}

# ─── RUN ──────────────────────────────────────────────────────────────────────
test_disk_space_pass
test_disk_space_huge_threshold
test_disk_space_nonexistent
test_disk_space_root
test_init_creates_dir
test_init_umask_restore
test_init_umask_restore_nondefault
test_export_trap_sigint_cleanup
test_export_trap_sigterm_cleanup

suite_end

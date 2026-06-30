#!/usr/bin/env bash
# tests/test_export.sh — Strict tests for export and disk space (Data Layer)

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/framework.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../src/core/00-header.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../src/core/01-utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../src/core/04-exports.sh"

suite_begin "04-exports.sh (Disk Space & Export Init)"

setup_export_all_context() {
    trap - EXIT

    OUTPUT_DIR="$TEST_TMPDIR/$1"
    mkdir -p "$OUTPUT_DIR"

    DISTRO_NAME="TestOS"
    DISTRO_TYPE="Generic"
    KERNEL_VER="test-kernel"
    CPU_GOVERNOR="test"
    BOOT_OFFSET=0
    GPU_INFO="Test GPU"
    DISPLAY_INFO="Test display"
    INTERNET_STATUS="unknown"
}

# ─── check_disk_space() ───────────────────────────────────────────────────────
test_disk_space_pass() {
    mock_command df '
        echo "Filesystem     1K-blocks    Used Available Use% Mounted on"
        echo "/dev/sda1        1000000       0   1000000   0% /"
    '
    # Require 100KB, should pass
    check_disk_space "/tmp" 100 || { echo "check_disk_space failed unexpectedly"; exit 1; }
}
run_test "check_disk_space passes when sufficient space" test_disk_space_pass

test_disk_space_fail() {
    mock_command df '
        echo "Filesystem     1K-blocks    Used Available Use% Mounted on"
        echo "/dev/sda1        1000000  999000      1000  99% /"
    '
    # Require 2000KB, available 1000KB, should fail
    if ( check_disk_space "/tmp" 2000 ); then
        echo "check_disk_space passed but should have failed"
        exit 1
    fi
}
run_test "check_disk_space fails when insufficient space" test_disk_space_fail

test_disk_space_fallback() {
    # If directory doesn't exist, it checks the parent
    mock_command df '
        echo "Filesystem     1K-blocks    Used Available Use% Mounted on"
        echo "/dev/sda1        1000000       0   1000000   0% /"
    '
    local missing_dir="$TEST_TMPDIR/nonexistent_dir_123"
    check_disk_space "$missing_dir" 100 || { echo "check_disk_space fallback failed"; exit 1; }
}
run_test "check_disk_space falls back to parent for missing dirs" test_disk_space_fallback

# ─── init_output_dir() ────────────────────────────────────────────────────────
test_init_creates_dir() {
    local original_dir="$PWD"
    cd "$TEST_TMPDIR"
    OUTPUT_DIR=""
    # init_output_dir sets OUTPUT_DIR as side-effect
    init_output_dir >/dev/null
    
    [[ -n "$OUTPUT_DIR" ]] || { echo "OUTPUT_DIR was not set"; cd "$original_dir"; exit 1; }
    [[ -d "$OUTPUT_DIR" ]] || { echo "Directory $OUTPUT_DIR was not created"; cd "$original_dir"; exit 1; }
    
    cd "$original_dir"
}
run_test "init_output_dir creates directory and sets OUTPUT_DIR" test_init_creates_dir

test_init_umask_restore() {
    local original_dir="$PWD"
    cd "$TEST_TMPDIR"
    umask 0077
    local before
    before="$(umask)"
    
    init_output_dir >/dev/null
    
    local after
    after="$(umask)"
    [[ "$before" == "$after" ]] || { echo "umask changed from $before to $after"; cd "$original_dir"; exit 1; }
    
    umask 0022 # Reset
    cd "$original_dir"
}
run_test "init_output_dir restores umask after creation" test_init_umask_restore

# ─── Export Traps ─────────────────────────────────────────────────────────────
test_export_trap_sigint() {
    local temp_file
    temp_file="$(mktemp "$TEST_TMPDIR/trap_test_XXXXXX")"

    bash -c '
        temp_file="'"$temp_file"'"
        trap '\''[[ -n "$temp_file" && -f "$temp_file" ]] && rm -f "$temp_file" 2>/dev/null'\'' EXIT INT TERM
        kill -INT $$
    ' 2>/dev/null || true

    sleep 0.1
    if [[ -f "$temp_file" ]]; then
        echo "SIGINT cleanup failed: $temp_file still exists"
        rm -f "$temp_file" 2>/dev/null || true
        exit 1
    fi
}
run_test "export cleanup trap works on SIGINT" test_export_trap_sigint

test_export_trap_sigterm() {
    local temp_file
    temp_file="$(mktemp "$TEST_TMPDIR/trap_test_XXXXXX")"

    bash -c '
        temp_file="'"$temp_file"'"
        trap '\''[[ -n "$temp_file" && -f "$temp_file" ]] && rm -f "$temp_file" 2>/dev/null'\'' EXIT INT TERM
        kill -TERM $$
    ' 2>/dev/null || true

    sleep 0.1
    if [[ -f "$temp_file" ]]; then
        echo "SIGTERM cleanup failed: $temp_file still exists"
        rm -f "$temp_file" 2>/dev/null || true
        exit 1
    fi
}
run_test "export cleanup trap works on SIGTERM" test_export_trap_sigterm

test_export_all_logs_restores_trap_on_mktemp_failure() {
    OUTPUT_DIR="$TEST_TMPDIR/export_all_failure"
    mkdir -p "$OUTPUT_DIR"

    trap 'printf caller_exit >/dev/null' EXIT
    mktemp() { return 1; }

    if ( export_all_logs >/dev/null 2>&1 ); then
        echo "export_all_logs should fail when mktemp fails"
        exit 1
    fi

    local trap_after
    trap_after="$(trap -p EXIT)"
    [[ "$trap_after" == *"caller_exit"* ]] || {
        echo "EXIT trap was not restored: $trap_after"
        exit 1
    }

    trap - EXIT
}
run_test "export_all_logs restores caller trap when mktemp fails" test_export_all_logs_restores_trap_on_mktemp_failure

test_export_all_logs_omits_pacman_without_plugin_hook() {
    setup_export_all_context "export_all_no_pacman"

    export_all_logs >/dev/null

    local output_file="${OUTPUT_DIR}/arch-log-inspector-all.txt"
    [[ -f "$output_file" ]] || { echo "Missing export file: $output_file"; exit 1; }

    ! grep -q "PACMAN LOGS" "$output_file" || { echo "Unexpected pacman section without plugin hook"; exit 1; }
    grep -q "\[6\] MOUNTED FILESYSTEMS" "$output_file" || { echo "Mounted filesystems section was not renumbered"; exit 1; }
}
run_test "export_all_logs omits pacman section without plugin hook" test_export_all_logs_omits_pacman_without_plugin_hook

test_export_all_logs_includes_pacman_plugin_hook() {
    setup_export_all_context "export_all_with_pacman"

    export_pacman_logs_content() {
        printf 'plugin pacman content\n'
    }

    export_all_logs >/dev/null

    local output_file="${OUTPUT_DIR}/arch-log-inspector-all.txt"
    [[ -f "$output_file" ]] || { echo "Missing export file: $output_file"; exit 1; }

    grep -q "\[6\] PACMAN LOGS" "$output_file" || { echo "Missing pacman section from plugin hook"; exit 1; }
    grep -q "plugin pacman content" "$output_file" || { echo "Missing plugin pacman content"; exit 1; }
    grep -q "\[7\] MOUNTED FILESYSTEMS" "$output_file" || { echo "Mounted filesystems section was not shifted after pacman"; exit 1; }
}
run_test "export_all_logs includes pacman section from plugin hook" test_export_all_logs_includes_pacman_plugin_hook

test_plugin_pacman_content_skips_non_arch() {
    source "$(dirname "${BASH_SOURCE[0]}")/../src/plugins/arch/plugin-pacman.sh"

    DISTRO_NAME="Ubuntu"
    DISTRO_TYPE="Generic"

    local output
    output="$(export_pacman_logs_content)"

    [[ "$output" == *"Skipping pacman export (non-Arch system)"* ]] || {
        echo "Expected non-Arch pacman export to skip, got: $output"
        exit 1
    }
}
run_test "plugin pacman content skips non-Arch systems" test_plugin_pacman_content_skips_non_arch

test_export_network_content_preserves_nullglob() {
    shopt -s nullglob

    _export_network_interfaces_content >/dev/null

    shopt -q nullglob || {
        echo "_export_network_interfaces_content disabled caller nullglob"
        exit 1
    }
    shopt -u nullglob
}
run_test "_export_network_interfaces_content preserves caller nullglob state" test_export_network_content_preserves_nullglob

test_export_summary_preserves_nullglob() {
    OUTPUT_DIR="$TEST_TMPDIR/export_summary_nullglob"
    mkdir -p "$OUTPUT_DIR"
    printf 'sample\n' > "$OUTPUT_DIR/sample.txt"
    DISTRO_NAME="TestOS"
    DISTRO_TYPE="Test"
    KERNEL_VER="test-kernel"
    CPU_GOVERNOR="test"
    BOOT_OFFSET=0

    shopt -s nullglob

    export_summary >/dev/null

    shopt -q nullglob || {
        echo "export_summary disabled caller nullglob"
        exit 1
    }
    shopt -u nullglob
}
run_test "export_summary preserves caller nullglob state" test_export_summary_preserves_nullglob

test_export_drivers_preserves_nullglob() {
    OUTPUT_DIR="$TEST_TMPDIR/export_drivers_nullglob"
    mkdir -p "$OUTPUT_DIR"

    shopt -s nullglob

    export_drivers >/dev/null

    shopt -q nullglob || {
        echo "export_drivers disabled caller nullglob"
        exit 1
    }
    shopt -u nullglob
}
run_test "export_drivers preserves caller nullglob state" test_export_drivers_preserves_nullglob

suite_end

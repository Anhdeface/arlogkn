#!/usr/bin/env bash
# tests/test_log_parsing.sh — Tests for log parsing / clustering functions
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test_framework.sh"

stub_globals
stub_logging
extract_function cluster_errors

suite_begin "Log Parsing"

# ─── cluster_errors() ─────────────────────────────────────────────────────────
test_cluster_empty() {
    # Empty input → empty output is success (0), not error (1)
    # This allows safe use in command substitution with set -e
    assert_exit_code "cluster_errors empty → exit 0 (success)" 0 cluster_errors ""
}

test_cluster_dedup() {
    local input
    input="$(printf 'error A\nerror A\nerror A\nerror B\n')"
    local output
    output="$(cluster_errors "$input")"
    assert_contains "cluster groups identical errors" "$output" "(x3)"
}

test_cluster_single() {
    local output
    output="$(cluster_errors "unique error line")"
    assert_contains "cluster single line passed through" "$output" "unique error line"
    assert_not_contains "cluster single line no (x)" "$output" "(x"
}

test_cluster_strip_syslog_timestamp() {
    local input="Mar 04 12:30:45 myhost kernel: some error"
    local output
    output="$(cluster_errors "$input")"
    assert_not_contains "cluster strips syslog timestamp" "$output" "Mar 04"
    assert_contains "cluster keeps message" "$output" "kernel: some error"
}

test_cluster_strip_iso_timestamp() {
    local input="2026-03-04T12:30:45+07:00 myhost kernel: another error"
    local output
    output="$(cluster_errors "$input")"
    assert_not_contains "cluster strips ISO timestamp" "$output" "2026-03-04"
    assert_contains "cluster keeps ISO message" "$output" "kernel: another error"
}

test_cluster_normalize_addr() {
    local input="segfault at 0x7fff1234abcd in module"
    local output
    output="$(cluster_errors "$input")"
    assert_contains "cluster normalizes address" "$output" "0xADDR"
    assert_not_contains "cluster replaces raw addr" "$output" "0x7fff1234abcd"
}

test_cluster_normalize_pid() {
    local input="process [12345] killed"
    local output
    output="$(cluster_errors "$input")"
    assert_contains "cluster normalizes PID" "$output" "[PID]"
    assert_not_contains "cluster replaces raw PID" "$output" "[12345]"
}

test_cluster_normalize_device() {
    local input="I/O error on sda1 sector 12345"
    local output
    output="$(cluster_errors "$input")"
    assert_contains "cluster normalizes device" "$output" "sdDEVICE"
}

test_cluster_normalize_mac() {
    local input="link aa:bb:cc:dd:ee:ff is down"
    local output
    output="$(cluster_errors "$input")"
    assert_contains "cluster normalizes MAC" "$output" "<MAC>"
}

test_cluster_percent_escape() {
    local input="100% disk usage on /dev/sda"
    local output
    output="$(cluster_errors "$input")"
    # Must not crash due to printf %s interpretation
    assert_contains "cluster handles percent sign" "$output" "100"
}

test_cluster_irq_normalize() {
    local input="IRQ 42 handler failed"
    local output
    output="$(cluster_errors "$input")"
    assert_contains "cluster normalizes IRQ" "$output" "IRQ N"
}

test_cluster_cpu_normalize() {
    local input="CPU 7 temperature exceeded threshold"
    local output
    output="$(cluster_errors "$input")"
    assert_contains "cluster normalizes CPU" "$output" "CPU N"
}

# ─── RUN ──────────────────────────────────────────────────────────────────────
test_cluster_empty
test_cluster_dedup
test_cluster_single
test_cluster_strip_syslog_timestamp
test_cluster_strip_iso_timestamp
test_cluster_normalize_addr
test_cluster_normalize_pid
test_cluster_normalize_device
test_cluster_normalize_mac
test_cluster_percent_escape
test_cluster_irq_normalize
test_cluster_cpu_normalize

suite_end

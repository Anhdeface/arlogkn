#!/usr/bin/env bash
# tests/test_log_parsing.sh — Strict tests for log parsing (Data Layer)

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/framework.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../src/core/03-logs.sh"

suite_begin "03-logs.sh (Log Parsing & Clustering)"

test_cluster_empty() {
    local output
    output="$(cluster_errors <<< "")"
    [[ "$output" == "" ]] || { echo "Expected empty output, got: $output"; exit 1; }
}
run_test "cluster_errors empty input yields empty output" test_cluster_empty

test_cluster_dedup() {
    local input
    input="$(printf 'error A\nerror A\nerror A\nerror B\n')"
    local output
    output="$(cluster_errors <<< "$input")"
    [[ "$output" == *"(x3)"* ]] || { echo "Expected (x3) in output, got: $output"; exit 1; }
}
run_test "cluster_errors groups identical errors" test_cluster_dedup

test_cluster_single() {
    local output
    output="$(cluster_errors <<< "unique error line")"
    [[ "$output" == *"unique error line"* ]] || { echo "Lost unique error line: $output"; exit 1; }
    [[ "$output" != *"(x"* ]] || { echo "Added unexpected count (x) to single line: $output"; exit 1; }
}
run_test "cluster_errors passes through single line without count" test_cluster_single

test_cluster_strip_syslog_timestamp() {
    local input="Mar 04 12:30:45 myhost kernel: some error"
    local output
    output="$(cluster_errors <<< "$input")"
    [[ "$output" != *"Mar 04"* ]] || { echo "Failed to strip syslog timestamp: $output"; exit 1; }
    [[ "$output" == *"kernel: some error"* ]] || { echo "Message truncated: $output"; exit 1; }
}
run_test "cluster_errors strips syslog timestamps" test_cluster_strip_syslog_timestamp

test_cluster_strip_iso_timestamp() {
    local input="2026-03-04T12:30:45+07:00 myhost kernel: another error"
    local output
    output="$(cluster_errors <<< "$input")"
    [[ "$output" != *"2026-03-04"* ]] || { echo "Failed to strip ISO timestamp: $output"; exit 1; }
    [[ "$output" == *"kernel: another error"* ]] || { echo "Message truncated: $output"; exit 1; }
}
run_test "cluster_errors strips ISO timestamps" test_cluster_strip_iso_timestamp

test_cluster_normalize_addr() {
    local input="segfault at 0x7fff1234abcd in module"
    local output
    output="$(cluster_errors <<< "$input")"
    [[ "$output" == *"0xADDR"* ]] || { echo "Failed to normalize address to 0xADDR: $output"; exit 1; }
    [[ "$output" != *"0x7fff1234abcd"* ]] || { echo "Did not replace raw address: $output"; exit 1; }
}
run_test "cluster_errors normalizes hex addresses" test_cluster_normalize_addr

test_cluster_normalize_pid() {
    local input="process [12345] killed"
    local output
    output="$(cluster_errors <<< "$input")"
    [[ "$output" == *"[PID]"* ]] || { echo "Failed to normalize PID to [PID]: $output"; exit 1; }
    [[ "$output" != *"[12345]"* ]] || { echo "Did not replace raw PID: $output"; exit 1; }
}
run_test "cluster_errors normalizes PIDs" test_cluster_normalize_pid

test_cluster_normalize_device() {
    local input="I/O error on sda1 sector 12345"
    local output
    output="$(cluster_errors <<< "$input")"
    [[ "$output" == *"sdDEVICE"* ]] || { echo "Failed to normalize device name: $output"; exit 1; }
}
run_test "cluster_errors normalizes sdX device names" test_cluster_normalize_device

test_cluster_normalize_mac() {
    local input="link aa:bb:cc:dd:ee:ff is down"
    local output
    output="$(cluster_errors <<< "$input")"
    [[ "$output" == *"<MAC>"* ]] || { echo "Failed to normalize MAC address: $output"; exit 1; }
}
run_test "cluster_errors normalizes MAC addresses" test_cluster_normalize_mac

test_cluster_percent_escape() {
    local input="100% disk usage on /dev/sda"
    local output
    output="$(cluster_errors <<< "$input")"
    [[ "$output" == *"100"* ]] || { echo "Lost percent number: $output"; exit 1; }
}
run_test "cluster_errors handles percent signs safely" test_cluster_percent_escape

test_cluster_irq_normalize() {
    local input="IRQ 42 handler failed"
    local output
    output="$(cluster_errors <<< "$input")"
    [[ "$output" == *"IRQ N"* ]] || { echo "Failed to normalize IRQ: $output"; exit 1; }
}
run_test "cluster_errors normalizes IRQ numbers" test_cluster_irq_normalize

test_cluster_cpu_normalize() {
    local input="CPU 7 temperature exceeded threshold"
    local output
    output="$(cluster_errors <<< "$input")"
    [[ "$output" == *"CPU N"* ]] || { echo "Failed to normalize CPU: $output"; exit 1; }
}
run_test "cluster_errors normalizes CPU indices" test_cluster_cpu_normalize

suite_end

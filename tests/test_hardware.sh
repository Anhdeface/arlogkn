#!/usr/bin/env bash
# tests/test_hardware.sh — Strict tests for hardware detection (Data Layer)

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/framework.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../src/core/02-hardware.sh"

suite_begin "02-hardware.sh (Data Accuracy & Mocking)"

# ─── detect_system_info() ─────────────────────────────────────────────────────
test_detect_system_info() {
    # Mock uname
    mock_command uname 'echo "6.9.0-mock-kernel"'
    
    detect_system_info
    
    [[ "$KERNEL_VER" == "6.9.0-mock-kernel" ]] || { echo "Kernel mismatch: $KERNEL_VER"; exit 1; }
    [[ -n "$CPU_GOVERNOR" ]] || { echo "CPU_GOVERNOR empty"; exit 1; }
}
run_test "detect_system_info parses kernel and governor" test_detect_system_info

# ─── _detect_gpu_lspci() ─────────────────────────────────────────────────────
test_detect_gpu_lspci_empty_output() {
    local result
    result="$(_detect_gpu_lspci "")"

    [[ -z "$result" ]] || { echo "Expected empty result, got $result"; exit 1; }
}
run_test "_detect_gpu_lspci handles empty lspci output without aborting" test_detect_gpu_lspci_empty_output

# ─── detect_distro() ──────────────────────────────────────────────────────────
test_detect_distro_arch() {
    # If /etc/os-release exists on host, it will use grep. We mock grep.
    mock_command grep '
        if [[ "$*" == *"^ID="* ]]; then echo "ID=arch"; return 0; fi
        if [[ "$*" == *"^ID_LIKE="* ]]; then echo "ID_LIKE=arch"; return 0; fi
        command grep "$@"
    '
    
    detect_distro
    
    # If host lacks /etc/os-release but has /etc/arch-release, id="arch".
    # Otherwise it might be "unknown". But assuming standard Linux host.
    if [[ -f /etc/os-release ]]; then
        [[ "$DISTRO_NAME" == "Arch Linux" ]] || { echo "Expected Arch Linux, got $DISTRO_NAME"; exit 1; }
        [[ "$DISTRO_TYPE" == "Pure Arch" ]] || { echo "Expected Pure Arch, got $DISTRO_TYPE"; exit 1; }
    fi
}
run_test "detect_distro identifies Arch Linux via grep mock" test_detect_distro_arch

test_detect_distro_missing_id_like() {
    mock_command grep '
        if [[ "$*" == *"^ID="* ]]; then echo "ID=arch"; return 0; fi
        if [[ "$*" == *"^ID_LIKE="* ]]; then return 1; fi
        command grep "$@"
    '

    detect_distro

    if [[ -f /etc/os-release ]]; then
        [[ "$DISTRO_NAME" == "Arch Linux" ]] || { echo "Expected Arch Linux, got $DISTRO_NAME"; exit 1; }
        [[ "$DISTRO_TYPE" == "Pure Arch" ]] || { echo "Expected Pure Arch, got $DISTRO_TYPE"; exit 1; }
    fi
}
run_test "detect_distro treats missing ID_LIKE as optional" test_detect_distro_missing_id_like

test_detect_distro_cachyos() {
    mock_command grep '
        if [[ "$*" == *"^ID="* ]]; then echo "ID=cachyos"; return 0; fi
        if [[ "$*" == *"^ID_LIKE="* ]]; then echo "ID_LIKE=arch"; return 0; fi
        command grep "$@"
    '
    
    detect_distro
    
    if [[ -f /etc/os-release ]]; then
        [[ "$DISTRO_NAME" == "CachyOS" ]] || { echo "Expected CachyOS, got $DISTRO_NAME"; exit 1; }
        [[ "$DISTRO_TYPE" == "Performance Tuned" ]] || { echo "Expected Performance Tuned, got $DISTRO_TYPE"; exit 1; }
    fi
}
run_test "detect_distro identifies CachyOS" test_detect_distro_cachyos

# ─── detect_network_status() ──────────────────────────────────────────────────
test_detect_network_status_connected() {
    export ARLOGKN_CHECK_EXTERNAL=1
    
    # Mock ping to succeed
    mock_command ping 'return 0'
    # Mock ip route to return a fake gateway
    mock_command ip '
        if [[ "$*" == *"route"* ]]; then echo "default via 192.168.1.1 dev eth0"; return 0; fi
        command ip "$@"
    '
    
    # Khởi tạo biến để tránh unbound variable trong môi trường test kín
    INTERNET_STATUS=""
    
    detect_network_status || true
    
    [[ "$INTERNET_STATUS" == "connected" ]] || { echo "Expected connected, got $INTERNET_STATUS"; exit 1; }
}
run_test "detect_network_status verifies external connection" test_detect_network_status_connected

test_detect_network_status_disconnected() {
    export ARLOGKN_CHECK_EXTERNAL=1
    
    # Mock ping to fail
    mock_command ping 'return 1'
    # Mock curl to fail
    mock_command curl 'return 1'
    # Mock ip route to return a fake gateway
    mock_command ip '
        if [[ "$*" == *"route"* ]]; then echo "default via 192.168.1.1 dev eth0"; return 0; fi
        command ip "$@"
    '
    
    # Khởi tạo biến
    INTERNET_STATUS=""

    # Run in subshell that doesn't trigger set -e since it returns 1
    if detect_network_status; then
        echo "Should have returned 1"
        exit 1
    fi
    
    # Even if disconnected from external, it might be ip_assigned if host has a valid IP!
    # Because detect_network_status checks /sys/class/net first.
    # So INTERNET_STATUS could be ip_assigned, link_up, or disconnected.
    [[ -n "$INTERNET_STATUS" ]] || { echo "INTERNET_STATUS empty"; exit 1; }
}
run_test "detect_network_status handles external failure gracefully" test_detect_network_status_disconnected

test_validate_external_url_blocks_private_literals() {
    local safe_url=""
    local curl_resolve=""

    if _validate_external_test_url "https://127.0.0.1/status" safe_url curl_resolve; then
        echo "Expected localhost IPv4 URL to be rejected"
        exit 1
    fi
    [[ "$safe_url" == "https://clients3.google.com/generate_204" ]] || { echo "Unexpected fallback URL: $safe_url"; exit 1; }
    [[ -z "$curl_resolve" ]] || { echo "Unexpected curl resolve: $curl_resolve"; exit 1; }

    if _validate_external_test_url "https://[::1]/status" safe_url curl_resolve; then
        echo "Expected localhost IPv6 URL to be rejected"
        exit 1
    fi
    [[ "$safe_url" == "https://clients3.google.com/generate_204" ]] || { echo "Unexpected fallback URL: $safe_url"; exit 1; }
    [[ -z "$curl_resolve" ]] || { echo "Unexpected curl resolve: $curl_resolve"; exit 1; }
}
run_test "_validate_external_test_url blocks private literal endpoints" test_validate_external_url_blocks_private_literals

test_validate_external_url_blocks_private_dns() {
    mock_command getent '
        if [[ "$1" == "ahosts" && "$2" == "metadata.example" ]]; then
            echo "10.0.0.5 STREAM metadata.example"
            return 0
        fi
        command getent "$@"
    '

    local safe_url=""
    local curl_resolve=""
    if _validate_external_test_url "https://metadata.example/check" safe_url curl_resolve; then
        echo "Expected hostname resolving to private IP to be rejected"
        exit 1
    fi

    [[ "$safe_url" == "https://clients3.google.com/generate_204" ]] || { echo "Unexpected fallback URL: $safe_url"; exit 1; }
    [[ -z "$curl_resolve" ]] || { echo "Unexpected curl resolve: $curl_resolve"; exit 1; }
}
run_test "_validate_external_test_url rejects hostnames resolving private" test_validate_external_url_blocks_private_dns

test_validate_external_url_dns_pins_public_host() {
    mock_command getent '
        if [[ "$1" == "ahosts" && "$2" == "example.com" ]]; then
            echo "93.184.216.34 STREAM example.com"
            return 0
        fi
        command getent "$@"
    '

    local safe_url=""
    local curl_resolve=""
    _validate_external_test_url "https://example.com:8443/check" safe_url curl_resolve

    [[ "$safe_url" == "https://example.com:8443/check" ]] || { echo "Unexpected safe URL: $safe_url"; exit 1; }
    [[ "$curl_resolve" == "example.com:8443:93.184.216.34" ]] || { echo "Unexpected curl resolve: $curl_resolve"; exit 1; }
}
run_test "_validate_external_test_url DNS-pins public hostnames" test_validate_external_url_dns_pins_public_host

test_detect_network_status_uses_dns_pinned_custom_url() {
    export ARLOGKN_CHECK_EXTERNAL=1
    export ARLOGKN_TEST_URL="https://example.com/check"

    mock_command ping 'return 1'
    mock_command ip '
        if [[ "$*" == *"route"* ]]; then echo "default via 192.168.1.1 dev eth0"; return 0; fi
        command ip "$@"
    '
    mock_command getent '
        if [[ "$1" == "ahosts" && "$2" == "example.com" ]]; then
            echo "93.184.216.34 STREAM example.com"
            return 0
        fi
        command getent "$@"
    '
    mock_command curl '
        local saw_resolve=0
        local saw_url=0
        while [[ "$#" -gt 0 ]]; do
            if [[ "$1" == "--resolve" && "${2:-}" == "example.com:443:93.184.216.34" ]]; then
                saw_resolve=1
                shift 2
                continue
            fi
            if [[ "$1" == "https://example.com/check" ]]; then
                saw_url=1
            fi
            shift
        done
        [[ "$saw_resolve" -eq 1 && "$saw_url" -eq 1 ]] || return 1
        printf "204"
    '

    INTERNET_STATUS=""
    detect_network_status

    [[ "$INTERNET_STATUS" == "connected" ]] || { echo "Expected connected, got $INTERNET_STATUS"; exit 1; }
}
run_test "detect_network_status uses DNS-pinned custom HTTP endpoint" test_detect_network_status_uses_dns_pinned_custom_url

suite_end

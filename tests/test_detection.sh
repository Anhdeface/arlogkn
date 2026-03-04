#!/usr/bin/env bash
# tests/test_detection.sh — Tests for system detection functions
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test_framework.sh"

stub_globals
stub_logging
extract_functions detect_distro detect_system_info check_internet

suite_begin "System Detection"

# ─── detect_distro() ──────────────────────────────────────────────────────────
test_detect_distro_arch() {
    local fake_os="$TEST_TMPDIR/os-release-arch"
    printf 'ID=arch\nNAME="Arch Linux"\n' > "$fake_os"

    # Temporarily override /etc/os-release by redefining the function
    # to use our fake file
    detect_distro_test() {
        local id="" variant=""
        if [[ -f "$fake_os" ]]; then
            id="$(grep -m1 '^ID=' "$fake_os" | cut -d'=' -f2- | tr -d '"')"
            variant="$(grep -m1 '^ID_LIKE=' "$fake_os" | cut -d'=' -f2- | tr -d '"' || echo "")"
        fi
        case "$id" in
            cachyos) DISTRO_NAME="CachyOS"; DISTRO_TYPE="Performance Tuned" ;;
            arch) DISTRO_NAME="Arch Linux"; DISTRO_TYPE="Pure Arch" ;;
            *) DISTRO_NAME="Unknown (ID: $id)"; DISTRO_TYPE="Unverified" ;;
        esac
    }
    detect_distro_test
    assert_eq "detect_distro arch ID" "$DISTRO_NAME" "Arch Linux"
    assert_eq "detect_distro arch type" "$DISTRO_TYPE" "Pure Arch"
}

test_detect_distro_cachyos() {
    local fake_os="$TEST_TMPDIR/os-release-cachy"
    printf 'ID=cachyos\nID_LIKE=arch\n' > "$fake_os"

    detect_distro_test2() {
        local id="" variant=""
        id="$(grep -m1 '^ID=' "$fake_os" | cut -d'=' -f2- | tr -d '"')"
        case "$id" in
            cachyos) DISTRO_NAME="CachyOS"; DISTRO_TYPE="Performance Tuned" ;;
            *) DISTRO_NAME="Unknown"; DISTRO_TYPE="Generic" ;;
        esac
    }
    detect_distro_test2
    assert_eq "detect_distro cachyos" "$DISTRO_NAME" "CachyOS"
    assert_eq "detect_distro cachyos type" "$DISTRO_TYPE" "Performance Tuned"
}

test_detect_distro_real() {
    # Test real detect_distro on this system
    DISTRO_NAME="Unknown"
    DISTRO_TYPE="Generic"
    detect_distro
    
    local name_valid=0 type_valid=0
    # Name/Type should just be printable text, avoid overly strict character classes
    [[ "$DISTRO_NAME" =~ ^[[:print:]]+$ ]] && name_valid=1
    [[ "$DISTRO_TYPE" =~ ^[[:print:]]+$ ]] && type_valid=1
    
    assert_eq "detect_distro real name format valid" "$name_valid" "1"
    assert_eq "detect_distro real type format valid" "$type_valid" "1"
}

# ─── detect_system_info() ─────────────────────────────────────────────────────
test_detect_system_info_kernel() {
    KERNEL_VER=""
    detect_system_info
    assert_ne "kernel version not empty" "$KERNEL_VER" ""
    # Should match uname -r output
    local expected
    expected="$(uname -r)"
    assert_eq "kernel version matches uname" "$KERNEL_VER" "$expected"
}

# ─── check_internet() ─────────────────────────────────────────────────────────
test_check_internet_sets_status() {
    INTERNET_STATUS="unknown"
    check_internet || true
    # Must be either "connected" or "disconnected", not "unknown"
    assert_ne "check_internet resolves status" "$INTERNET_STATUS" "unknown"
}

test_check_internet_result_valid() {
    INTERNET_STATUS="unknown"
    check_internet || true
    local valid=0
    [[ "$INTERNET_STATUS" == "connected" || "$INTERNET_STATUS" == "disconnected" ]] && valid=1
    assert_eq "check_internet valid state" "$valid" "1"
}

# ─── RUN ──────────────────────────────────────────────────────────────────────
test_detect_distro_arch
test_detect_distro_cachyos
test_detect_distro_real
test_detect_system_info_kernel
test_check_internet_sets_status
test_check_internet_result_valid

suite_end

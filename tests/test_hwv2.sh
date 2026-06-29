#!/usr/bin/env bash
# tests/test_hwv2.sh — Strict tests for HWV2 plugin exports

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/framework.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../src/core/00-header.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../src/core/01-utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../src/plugins/hwv2/plugin-hw-deep.sh"

suite_begin "plugin-hw-deep.sh (HWV2 Exports)"

test_export_storage_v2_invalid_output_dir() {
    OUTPUT_DIR=""
    if ( export_storage_v2 ); then
        echo "export_storage_v2 should fail without OUTPUT_DIR"
        exit 1
    fi
}
run_test "export_storage_v2 rejects missing OUTPUT_DIR" test_export_storage_v2_invalid_output_dir

test_export_peripherals_v2_invalid_output_dir() {
    OUTPUT_DIR=""
    if ( export_peripherals_v2 ); then
        echo "export_peripherals_v2 should fail without OUTPUT_DIR"
        exit 1
    fi
}
run_test "export_peripherals_v2 rejects missing OUTPUT_DIR" test_export_peripherals_v2_invalid_output_dir

test_export_storage_v2_writes_file() {
    OUTPUT_DIR="$TEST_TMPDIR/hwv2_export"
    mkdir -p "$OUTPUT_DIR"

    export_storage_v2 >/dev/null

    [[ -s "$OUTPUT_DIR/storage_v2.txt" ]] || {
        echo "storage_v2.txt missing or empty"
        exit 1
    }
    grep -qF "STORAGE DEVICES (HWV2)" "$OUTPUT_DIR/storage_v2.txt" || {
        echo "storage_v2.txt missing header"
        exit 1
    }
}
run_test "export_storage_v2 writes storage_v2.txt" test_export_storage_v2_writes_file

test_export_peripherals_v2_writes_file() {
    OUTPUT_DIR="$TEST_TMPDIR/hwv2_export"
    mkdir -p "$OUTPUT_DIR"

    export_peripherals_v2 >/dev/null

    [[ -s "$OUTPUT_DIR/peripherals_v2.txt" ]] || {
        echo "peripherals_v2.txt missing or empty"
        exit 1
    }
    grep -qF "PERIPHERALS (HWV2)" "$OUTPUT_DIR/peripherals_v2.txt" || {
        echo "peripherals_v2.txt missing header"
        exit 1
    }
}
run_test "export_peripherals_v2 writes peripherals_v2.txt" test_export_peripherals_v2_writes_file

suite_end

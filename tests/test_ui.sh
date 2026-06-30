#!/usr/bin/env bash
# tests/test_ui.sh — Strict tests for UI and Box drawing functions (UI Layer)

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/framework.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../src/core/00-header.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../src/core/01-utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../src/core/02-hardware.sh"

suite_begin "02-hardware.sh (UI & Box Drawing)"

# ─── draw_header() ────────────────────────────────────────────────────────────
test_draw_header_contains_title() {
    local output
    output="$(draw_header "TEST TITLE" 70)"
    [[ "$output" == *"TEST TITLE"* ]] || { echo "draw_header missing title: $output"; exit 1; }
}
run_test "draw_header contains provided title" test_draw_header_contains_title

test_draw_header_has_borders() {
    local output
    output="$(draw_header "HDR" 70)"
    [[ "$output" == *"─"* ]] || { echo "draw_header missing border characters: $output"; exit 1; }
}
run_test "draw_header has proper box border characters" test_draw_header_has_borders

# ─── draw_section_header() ────────────────────────────────────────────────────
test_draw_section_header_format() {
    local output
    output="$(draw_section_header "KERNEL ERRORS")"
    [[ "$output" == *"──["* ]] || { echo "draw_section_header missing brackets: $output"; exit 1; }
    [[ "$output" == *"KERNEL ERRORS"* ]] || { echo "draw_section_header missing title: $output"; exit 1; }
}
run_test "draw_section_header formats correctly" test_draw_section_header_format

# ─── draw_box_line() ──────────────────────────────────────────────────────────
test_draw_box_line_short() {
    local output
    output="$(draw_box_line "short text" 70)"
    [[ "$output" == *"short text"* ]] || { echo "draw_box_line missing text: $output"; exit 1; }
}
run_test "draw_box_line outputs short text normally" test_draw_box_line_short

test_draw_box_line_truncation() {
    local long_text
    long_text="$(printf '%0.s_' {1..200})"
    local output
    output="$(draw_box_line "$long_text" 70)"
    [[ "$output" == *"..."* ]] || { echo "draw_box_line failed to add ... truncation suffix"; exit 1; }
}
run_test "draw_box_line truncates long strings with ..." test_draw_box_line_truncation

# ─── draw_empty_box() ─────────────────────────────────────────────────────────
test_draw_empty_box_message() {
    local output
    output="$(draw_empty_box 70)"
    [[ "$output" == *"No Critical Issues"* ]] || { echo "draw_empty_box missing default message: $output"; exit 1; }
}
run_test "draw_empty_box displays 'No Critical Issues'" test_draw_empty_box_message

# ─── draw_info_box() ──────────────────────────────────────────────────────────
test_draw_info_box_format() {
    local output
    output="$(draw_info_box "Kernel" "5.15.0" 70)"
    [[ "$output" == *"Kernel"* ]] || { echo "draw_info_box missing label: $output"; exit 1; }
    [[ "$output" == *"5.15.0"* ]] || { echo "draw_info_box missing value: $output"; exit 1; }
    [[ "$output" == *":"* ]] || { echo "draw_info_box missing colon: $output"; exit 1; }
}
run_test "draw_info_box correctly formats key-value pair" test_draw_info_box_format

# ─── scan_vga_info() ──────────────────────────────────────────────────────────
test_scan_vga_info_missing_glx_fields() {
    GPU_INFO="Unknown"
    DISPLAY_INFO="No display detected"
    mock_command glxinfo 'printf "%s\n" "name of display: :0"'

    scan_vga_info >/dev/null
}
run_test "scan_vga_info tolerates glxinfo output without OpenGL fields" test_scan_vga_info_missing_glx_fields

suite_end

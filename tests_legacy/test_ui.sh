#!/usr/bin/env bash
# tests/test_ui.sh — Tests for UI / box drawing functions
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test_framework.sh"

stub_globals
stub_logging
extract_functions strip_ansi visible_len draw_header draw_section_header draw_box_line draw_empty_box draw_info_box

suite_begin "UI / Box Drawing"

# ─── draw_header() ────────────────────────────────────────────────────────────
test_draw_header_contains_title() {
    local output
    output="$(draw_header "TEST TITLE" 70)"
    assert_contains "draw_header contains title" "$output" "TEST TITLE"
}

test_draw_header_has_borders() {
    local output
    output="$(draw_header "HDR" 70)"
    assert_contains "draw_header has border chars" "$output" "─"
}

# ─── draw_section_header() ────────────────────────────────────────────────────
test_draw_section_header_format() {
    local output
    output="$(draw_section_header "KERNEL ERRORS")"
    assert_contains "section header has brackets" "$output" "──["
    assert_contains "section header has title" "$output" "KERNEL ERRORS"
}

# ─── draw_box_line() ──────────────────────────────────────────────────────────
test_draw_box_line_short() {
    local output
    output="$(draw_box_line "short text" 70)"
    assert_contains "box_line contains text" "$output" "short text"
}

test_draw_box_line_truncation() {
    local long_text
    long_text="$(printf '%0.s_' {1..200})"
    local output
    output="$(draw_box_line "$long_text" 70)"
    assert_contains "box_line truncates with ..." "$output" "..."
}

# ─── draw_empty_box() ─────────────────────────────────────────────────────────
test_draw_empty_box_message() {
    local output
    output="$(draw_empty_box 70)"
    assert_contains "empty_box shows no issues" "$output" "No Critical Issues"
}

# ─── draw_info_box() ──────────────────────────────────────────────────────────
test_draw_info_box_format() {
    local output
    output="$(draw_info_box "Kernel" "5.15.0" 70)"
    assert_contains "info_box has label" "$output" "Kernel"
    assert_contains "info_box has value" "$output" "5.15.0"
    assert_contains "info_box has colon" "$output" ":"
}

# ─── RUN ──────────────────────────────────────────────────────────────────────
test_draw_header_contains_title
test_draw_header_has_borders
test_draw_section_header_format
test_draw_box_line_short
test_draw_box_line_truncation
test_draw_empty_box_message
test_draw_info_box_format

suite_end

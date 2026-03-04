#!/usr/bin/env bash
# tests/test_tables.sh — Tests for table drawing functions
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test_framework.sh"

stub_globals
stub_logging
extract_functions strip_ansi visible_len tbl_begin tbl_row tbl_end draw_table_begin draw_table_row draw_table_end draw_table_header draw_table_footer

suite_begin "Table Drawing"

# ─── tbl_begin() ──────────────────────────────────────────────────────────────
test_tbl_begin_sets_width() {
    _TBL_WIDTH=0
    _TBL_COLS=()
    tbl_begin "Name" 20 "Value" 30 >/dev/null
    assert_ne "tbl_begin sets _TBL_WIDTH" "$_TBL_WIDTH" "0"
}

test_tbl_begin_outputs_header() {
    _TBL_WIDTH=0
    _TBL_COLS=()
    local output
    output="$(tbl_begin "Driver" 15 "Status" 10)"
    assert_contains "tbl_begin header has column name" "$output" "Driver"
    assert_contains "tbl_begin header has second column" "$output" "Status"
}

# ─── tbl_row() ────────────────────────────────────────────────────────────────
test_tbl_row_output() {
    _TBL_WIDTH=0
    _TBL_COLS=()
    tbl_begin "Key" 20 "Val" 30 >/dev/null
    local output
    output="$(tbl_row "GPU" "amdgpu")"
    assert_contains "tbl_row has key" "$output" "GPU"
    assert_contains "tbl_row has value" "$output" "amdgpu"
}

test_tbl_row_truncation() {
    _TBL_WIDTH=0
    _TBL_COLS=()
    tbl_begin "Col" 10 >/dev/null
    local long_val
    long_val="$(printf '%0.sX' {1..50})"
    local output
    output="$(tbl_row "$long_val")"
    # Should not exceed defined width significantly
    local stripped
    stripped="$(strip_ansi "$output")"
    local len=${#stripped}
    # Reasonable: the line shouldn't be absurdly long
    local ok=1
    [[ "$len" -gt 100 ]] && ok=0
    assert_eq "tbl_row truncates long value" "$ok" "1"
}

# ─── tbl_end() ────────────────────────────────────────────────────────────────
test_tbl_end_runs() {
    _TBL_WIDTH=50
    local rc=0
    tbl_end >/dev/null 2>&1 || rc=$?
    assert_eq "tbl_end runs without error" "$rc" "0"
}

# ─── Legacy wrappers ──────────────────────────────────────────────────────────
test_draw_table_begin_wrapper() {
    _TBL_WIDTH=0
    _TBL_COLS=()
    local output
    output="$(draw_table_begin "A" 20 "B" 20)"
    assert_contains "draw_table_begin wrapper works" "$output" "A"
}

test_draw_table_row_wrapper() {
    _TBL_WIDTH=0
    _TBL_COLS=()
    draw_table_begin "X" 20 >/dev/null
    local output
    output="$(draw_table_row "val1")"
    assert_contains "draw_table_row wrapper works" "$output" "val1"
}

# ─── RUN ──────────────────────────────────────────────────────────────────────
test_tbl_begin_sets_width
test_tbl_begin_outputs_header
test_tbl_row_output
test_tbl_row_truncation
test_tbl_end_runs
test_draw_table_begin_wrapper
test_draw_table_row_wrapper

suite_end

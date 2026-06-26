#!/usr/bin/env bash
# tests/test_tables.sh — Strict tests for table drawing functions (UI Layer)

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/framework.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../src/core/01-utils.sh"

suite_begin "01-utils.sh (Table Drawing)"

# ─── tbl_begin() ──────────────────────────────────────────────────────────────
test_tbl_begin_sets_width() {
    _TBL_DEPTH=-1; _TBL_WIDTH_STACK=(); _TBL_COLS_STACK=(); _TBL_COLS_PTR_STACK=(); _TBL_NUMCOLS_STACK=()
    tbl_begin "Name" 20 "Value" 30 >/dev/null
    [[ "${_TBL_WIDTH_STACK[0]:-0}" != "0" ]] || { echo "tbl_begin did not set _TBL_WIDTH"; exit 1; }
}
run_test "tbl_begin sets internal _TBL_WIDTH_STACK state" test_tbl_begin_sets_width

test_tbl_begin_outputs_header() {
    _TBL_DEPTH=-1; _TBL_WIDTH_STACK=(); _TBL_COLS_STACK=(); _TBL_COLS_PTR_STACK=(); _TBL_NUMCOLS_STACK=()
    local output
    output="$(tbl_begin "Driver" 15 "Status" 10)"
    [[ "$output" == *"Driver"* ]] || { echo "Header missing 'Driver': $output"; exit 1; }
    [[ "$output" == *"Status"* ]] || { echo "Header missing 'Status': $output"; exit 1; }
}
run_test "tbl_begin outputs table header with column names" test_tbl_begin_outputs_header

# ─── tbl_row() ────────────────────────────────────────────────────────────────
test_tbl_row_output() {
    _TBL_DEPTH=-1; _TBL_WIDTH_STACK=(); _TBL_COLS_STACK=(); _TBL_COLS_PTR_STACK=(); _TBL_NUMCOLS_STACK=()
    tbl_begin "Key" 20 "Val" 30 >/dev/null
    local output
    output="$(tbl_row "GPU" "amdgpu")"
    [[ "$output" == *"GPU"* ]] || { echo "Row missing key 'GPU': $output"; exit 1; }
    [[ "$output" == *"amdgpu"* ]] || { echo "Row missing value 'amdgpu': $output"; exit 1; }
}
run_test "tbl_row outputs values matching columns" test_tbl_row_output

test_tbl_row_truncation() {
    _TBL_DEPTH=-1; _TBL_WIDTH_STACK=(); _TBL_COLS_STACK=(); _TBL_COLS_PTR_STACK=(); _TBL_NUMCOLS_STACK=()
    tbl_begin "Col" 10 >/dev/null
    local long_val
    long_val="$(printf '%0.sX' {1..50})"
    local output
    output="$(tbl_row "$long_val")"
    
    local stripped
    stripped="$(strip_ansi "$output")"
    local len=${#stripped}
    # It shouldn't exceed the total table width (10) plus borders (~6)
    [[ "$len" -lt 30 ]] || { echo "Value was not truncated properly, length $len > 30"; exit 1; }
}
run_test "tbl_row truncates extremely long values" test_tbl_row_truncation

# ─── tbl_end() ────────────────────────────────────────────────────────────────
test_tbl_end_runs() {
    _TBL_DEPTH=0; _TBL_WIDTH_STACK=(50); _TBL_COLS_PTR_STACK=(0); _TBL_NUMCOLS_STACK=(1)
    # Should not throw errors
    tbl_end >/dev/null
}
run_test "tbl_end executes cleanly" test_tbl_end_runs

# ─── Legacy wrappers ──────────────────────────────────────────────────────────
test_draw_table_begin_wrapper() {
    _TBL_DEPTH=-1; _TBL_WIDTH_STACK=(); _TBL_COLS_STACK=(); _TBL_COLS_PTR_STACK=(); _TBL_NUMCOLS_STACK=()
    local output
    output="$(draw_table_begin "A" 20 "B" 20)"
    [[ "$output" == *"A"* ]] || { echo "Wrapper failed to pass column name 'A'"; exit 1; }
}
run_test "draw_table_begin wrapper passes through to tbl_begin" test_draw_table_begin_wrapper

test_draw_table_row_wrapper() {
    _TBL_DEPTH=-1; _TBL_WIDTH_STACK=(); _TBL_COLS_STACK=(); _TBL_COLS_PTR_STACK=(); _TBL_NUMCOLS_STACK=()
    draw_table_begin "X" 20 >/dev/null
    local output
    output="$(draw_table_row "val1")"
    [[ "$output" == *"val1"* ]] || { echo "Wrapper failed to pass row value 'val1'"; exit 1; }
}
run_test "draw_table_row wrapper passes through to tbl_row" test_draw_table_row_wrapper

suite_end

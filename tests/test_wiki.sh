#!/usr/bin/env bash
# tests/test_wiki.sh — Tests for wiki fuzzy matching functions
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test_framework.sh"

stub_globals
stub_logging
extract_functions awk_fuzzy_match find_wiki_group_awk suggest_wiki_groups_awk

# Set up WIKI data structures (same as in arch-diag.sh)
declare -a WIKI_GROUP_NAMES=(
    "pacman package management"
    "aur helper"
    "system administration"
    "process management"
    "hardware diagnostics"
    "disk partition"
    "network troubleshooting"
    "user management"
    "logs journal"
    "arch installation"
    "performance tuning"
    "backup restore"
    "troubleshooting debug"
    "boot startup repair"
    "memory swap"
    "graphics display gpu"
    "sound audio pulseaudio"
    "systemd journal"
    "file permission debug"
    "emergency recovery"
)

declare -A WIKI_ALIASES=(
    ["gpu"]="graphics"
    ["net"]="network"
    ["pkg"]="pacman"
    ["mem"]="memory"
    ["sys"]="system"
    ["proc"]="process"
    ["hw"]="hardware"
    ["audio"]="sound"
    ["display"]="graphics"
    ["cpu"]="system"
    ["drive"]="disk"
    ["storage"]="disk"
    ["service"]="process"
    ["journal"]="logs"
    ["perm"]="file"
    ["recover"]="emergency"
)

suite_begin "Wiki Fuzzy Matching"

# ─── awk_fuzzy_match() ────────────────────────────────────────────────────────
test_awk_exact_match() {
    local groups
    groups="$(printf '%s\n' "sound" "network" "display")"
    local result
    result="$(awk_fuzzy_match "sound" "$groups")"
    assert_eq "exact match sound" "$result" "0:0"
}

test_awk_typo_match() {
    local groups
    groups="$(printf '%s\n' "sound" "network" "display")"
    local result
    result="$(awk_fuzzy_match "soond" "$groups")"
    assert_regex "typo match soond" "$result" "^0:[12]$"
}

test_awk_no_match() {
    local groups
    groups="$(printf '%s\n' "sound" "network" "display")"
    local result
    result="$(awk_fuzzy_match "zzzzzzz" "$groups")"
    assert_eq "no match returns -1:999" "$result" "-1:999"
}

test_awk_empty_query() {
    local groups
    groups="$(printf '%s\n' "sound" "network")"
    assert_exit_code "empty query returns 1" 1 awk_fuzzy_match "" "$groups"
}

test_awk_injection_dquote() {
    local groups
    groups="$(printf '%s\n' "sound" "network")"
    local result
    result="$(awk_fuzzy_match 'a"b' "$groups" 2>&1)" || true
    assert_not_contains "dquote injection blocked" "$result" "uid="
    assert_regex "dquote returns valid format" "$result" "^-?[0-9]+:[0-9]+$"
}

test_awk_injection_system() {
    local groups
    groups="$(printf '%s\n' "sound" "network")"
    local result
    result="$(awk_fuzzy_match '"; system("id"); "' "$groups" 2>&1)" || true
    assert_not_contains "system() injection blocked" "$result" "uid="
}

test_awk_injection_backslash() {
    local groups
    groups="$(printf '%s\n' "sound" "network")"
    local result
    result="$(awk_fuzzy_match 'a\b' "$groups" 2>&1)" || true
    assert_not_contains "backslash injection blocked" "$result" "uid="
}

test_awk_long_query_truncated() {
    local groups
    groups="$(printf '%s\n' "sound")"
    local long_q
    long_q="$(printf '%0.sa' {1..60})"
    local result
    result="$(awk_fuzzy_match "$long_q" "$groups" 2>&1)" || true
    # Should not crash, should return valid format
    assert_regex "long query handled" "$result" "^-?[0-9]+:[0-9]+$"
}

# ─── find_wiki_group_awk() ────────────────────────────────────────────────────
test_find_group_alias() {
    local result
    result="$(find_wiki_group_awk "gpu")"
    # "gpu" → alias "graphics" → should match index 15 (graphics display gpu)
    assert_eq "alias gpu → index 15" "$result" "15"
}

test_find_group_exact() {
    local result
    result="$(find_wiki_group_awk "sound")"
    # "sound" → exact match in group 16 (sound audio pulseaudio)
    assert_eq "exact match sound → 16" "$result" "16"
}

test_find_group_fuzzy() {
    local result
    result="$(find_wiki_group_awk "soud")"
    # "soud" → fuzzy to "sound" group
    assert_regex "fuzzy soud → numeric index" "$result" "^[0-9]+$"
}

test_find_group_invalid() {
    assert_exit_code "invalid group returns 1" 1 find_wiki_group_awk "zzzzzzzzz"
    local result
    result="$(find_wiki_group_awk "zzzzzzzzz")" || true
    assert_eq "invalid group output format is -1" "$result" "-1"
}

test_find_group_empty() {
    assert_exit_code "empty group query returns 1" 1 find_wiki_group_awk ""
    local result=0
    result="$(find_wiki_group_awk "" 2>/dev/null)" || true
    assert_eq "empty group output format is -1" "$result" "-1"
}

# ─── suggest_wiki_groups_awk() ────────────────────────────────────────────────
test_suggest_returns_results() {
    local output
    output="$(suggest_wiki_groups_awk "networ")" || true
    assert_ne "suggest has output" "$output" ""
}

test_suggest_max_three() {
    local output
    output="$(suggest_wiki_groups_awk "a")" || true
    local count
    count="$(printf '%s\n' "$output" | wc -l)"
    local ok=1
    [[ "$count" -gt 3 ]] && ok=0
    assert_eq "suggest max 3 results" "$ok" "1"
}

test_suggest_injection() {
    local output
    output="$(suggest_wiki_groups_awk '"; system("id"); "' 2>&1)" || true
    assert_not_contains "suggest injection blocked" "$output" "uid="
}

# ─── RUN ──────────────────────────────────────────────────────────────────────
test_awk_exact_match
test_awk_typo_match
test_awk_no_match
test_awk_empty_query
test_awk_injection_dquote
test_awk_injection_system
test_awk_injection_backslash
test_awk_long_query_truncated
test_find_group_alias
test_find_group_exact
test_find_group_fuzzy
test_find_group_invalid
test_find_group_empty
test_suggest_returns_results
test_suggest_max_three
test_suggest_injection

suite_end

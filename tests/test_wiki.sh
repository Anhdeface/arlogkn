#!/usr/bin/env bash
# tests/test_wiki.sh — Strict tests for Wiki fuzzy matching (Data Layer)

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/framework.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../src/core/05-wiki.sh"

# Note: The wiki logic needs WIKI_GROUP_NAMES array to be exported/defined
# which normally happens in 05-wiki.sh or 99-main.sh. 05-wiki.sh defines them.

suite_begin "05-wiki.sh (Fuzzy Matching)"

# ─── awk_fuzzy_match() ────────────────────────────────────────────────────────
test_awk_exact_match() {
    local groups
    groups="$(printf '%s\n' "sound" "network" "display")"
    local result
    result="$(awk_fuzzy_match "sound" "$groups")"
    [[ "$result" == "0:0" ]] || { echo "Expected 0:0, got $result"; exit 1; }
}
run_test "awk_fuzzy_match identifies exact matches" test_awk_exact_match

test_awk_typo_match() {
    local groups
    groups="$(printf '%s\n' "sound" "network" "display")"
    local result
    result="$(awk_fuzzy_match "soond" "$groups")"
    [[ "$result" =~ ^0:[12]$ ]] || { echo "Expected typo match (distance 1 or 2), got $result"; exit 1; }
}
run_test "awk_fuzzy_match identifies matches with typos" test_awk_typo_match

test_awk_no_match() {
    local groups
    groups="$(printf '%s\n' "sound" "network" "display")"
    local result
    result="$(awk_fuzzy_match "zzzzzzz" "$groups")"
    [[ "$result" == "-1:999" ]] || { echo "Expected -1:999, got $result"; exit 1; }
}
run_test "awk_fuzzy_match returns -1:999 for no match" test_awk_no_match

test_awk_empty_query() {
    local groups
    groups="$(printf '%s\n' "sound" "network")"
    if ( awk_fuzzy_match "" "$groups" ); then
        echo "Expected failure on empty query"
        exit 1
    fi
}
run_test "awk_fuzzy_match fails safely on empty query" test_awk_empty_query

test_awk_injection_dquote() {
    local groups
    groups="$(printf '%s\n' "sound" "network")"
    local result
    result="$(awk_fuzzy_match 'a"b' "$groups" 2>&1)" || true
    [[ "$result" != *"uid="* ]] || { echo "Injection succeeded: $result"; exit 1; }
    [[ "$result" =~ ^-?[0-9]+:[0-9]+$ ]] || { echo "Invalid format returned: $result"; exit 1; }
}
run_test "awk_fuzzy_match blocks double quote injection" test_awk_injection_dquote

test_awk_injection_system() {
    local groups
    groups="$(printf '%s\n' "sound" "network")"
    local result
    result="$(awk_fuzzy_match '"; system("id"); "' "$groups" 2>&1)" || true
    [[ "$result" != *"uid="* ]] || { echo "Injection succeeded: $result"; exit 1; }
}
run_test "awk_fuzzy_match blocks system() call injection" test_awk_injection_system

# ─── find_wiki_group_awk() ────────────────────────────────────────────────────
test_find_group_alias() {
    local result
    result="$(find_wiki_group_awk "gpu")"
    # "gpu" → alias "graphics" → should match index 15 (graphics display gpu)
    [[ "$result" == "15" ]] || { echo "Expected 15, got $result"; exit 1; }
}
run_test "find_wiki_group_awk resolves aliases" test_find_group_alias

test_find_group_exact() {
    local result
    result="$(find_wiki_group_awk "sound")"
    # "sound" → exact match in group 16 (sound audio pulseaudio)
    [[ "$result" == "16" ]] || { echo "Expected 16, got $result"; exit 1; }
}
run_test "find_wiki_group_awk finds exact matches" test_find_group_exact

test_find_group_invalid() {
    if ( find_wiki_group_awk "zzzzzzzzz" >/dev/null ); then
        echo "Expected failure on invalid group"
        exit 1
    fi
}
run_test "find_wiki_group_awk fails on completely invalid group" test_find_group_invalid

# ─── suggest_wiki_groups_awk() ────────────────────────────────────────────────
test_suggest_returns_results() {
    local output
    output="$(suggest_wiki_groups_awk "networ")" || true
    [[ -n "$output" ]] || { echo "Expected output, got empty"; exit 1; }
}
run_test "suggest_wiki_groups_awk returns suggestions" test_suggest_returns_results

test_suggest_max_three() {
    local output
    output="$(suggest_wiki_groups_awk "a")" || true
    local count
    count="$(printf '%s\n' "$output" | wc -l)"
    [[ "$count" -le 3 ]] || { echo "Expected max 3 results, got $count"; exit 1; }
}
run_test "suggest_wiki_groups_awk limits results to 3" test_suggest_max_three

suite_end

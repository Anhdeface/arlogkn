#!/usr/bin/env bash
# tests/test_wiki.sh — Strict tests for Wiki fuzzy matching (Data Layer)

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/framework.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../src/core/00-header.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../src/core/01-utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../src/core/02-hardware.sh"
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
    # "gpu" → alias "graphics" → should match index 12 (graphics display gpu)
    [[ "$result" == "12" ]] || { echo "Expected 12, got $result"; exit 1; }
}
run_test "find_wiki_group_awk resolves aliases" test_find_group_alias

test_find_group_exact() {
    local result
    result="$(find_wiki_group_awk "sound")"
    # "sound" → exact match in group 13 (sound audio pulseaudio)
    [[ "$result" == "13" ]] || { echo "Expected 13, got $result"; exit 1; }
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

# ─── Wiki group rendering ────────────────────────────────────────────────────
test_show_wiki_group_sound_renders() {
    local output
    output="$(show_wiki_group 13)"
    [[ "$output" == *"SOUND & AUDIO"* ]] || { echo "Missing sound header"; exit 1; }
    [[ "$output" == *"pactl info"* ]] || { echo "Missing sound command row"; exit 1; }
}
run_test "show_wiki_group renders sound group without executing title text" test_show_wiki_group_sound_renders

test_show_wiki_group_all_core_handlers_render() {
    local i output
    for ((i = 0; i < ${#WIKI_GROUP_NAMES[@]}; i++)); do
        output="$(show_wiki_group "$i" 80)" || {
            echo "show_wiki_group failed for index $i (${WIKI_GROUP_KEYS[$i]})"
            exit 1
        }
        [[ "$output" == *"Command"* ]] || {
            echo "Missing command table for index $i (${WIKI_GROUP_KEYS[$i]})"
            exit 1
        }
    done
}
run_test "show_wiki_group renders every core wiki handler" test_show_wiki_group_all_core_handlers_render

test_show_help_omits_plugin_groups_until_loaded() {
    local output
    output="$(show_help)"

    [[ "$output" == *"system, process, hardware"* ]] || { echo "Core wiki groups missing from help"; exit 1; }
    [[ "$output" != *"pacman"* ]] || { echo "Help exposed pacman without Arch wiki plugin"; exit 1; }
    [[ "$output" != *"aur"* ]] || { echo "Help exposed AUR without Arch wiki plugin"; exit 1; }
}
run_test "show_help omits plugin wiki groups until loaded" test_show_help_omits_plugin_groups_until_loaded

test_show_help_includes_plugin_groups_when_loaded() {
    source "$(dirname "${BASH_SOURCE[0]}")/../src/plugins/arch/plugin-wiki.sh"

    local output
    output="$(show_help)"

    [[ "$output" == *"pacman"* ]] || { echo "Help missing pacman group after plugin load"; exit 1; }
    [[ "$output" == *"aur"* ]] || { echo "Help missing AUR group after plugin load"; exit 1; }
    [[ "$output" == *"arch"* ]] || { echo "Help missing arch group after plugin load"; exit 1; }
}
run_test "show_help includes plugin wiki groups when loaded" test_show_help_includes_plugin_groups_when_loaded

test_show_wiki_unknown_uses_dynamic_group_count() {
    WIKI_GROUP="zzzzzzzzz"

    local output
    output="$(show_wiki)" || true

    [[ "$output" == *"Available groups: 1-${#WIKI_GROUP_NAMES[@]} or keywords"* ]] || {
        echo "Invalid group help did not use dynamic group count"
        exit 1
    }
    [[ "$output" != *"--wiki pacman"* ]] || {
        echo "Invalid group help exposed pacman without Arch wiki plugin"
        exit 1
    }
}
run_test "show_wiki invalid-group help uses dynamic core groups" test_show_wiki_unknown_uses_dynamic_group_count

suite_end

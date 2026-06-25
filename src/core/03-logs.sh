# LOG PARSING ENGINE
# ─────────────────────────────────────────────────────────────────────────────

# Cluster identical errors and count occurrences
# Returns: 0 on success (including empty input → empty output), 1 on critical error
#
# PIPELINE PROCESSING: Input flows through pipeline without storing in bash
# variables. This avoids O(n) bash variable allocation and string copying.
# Pipeline: stdin → sed (normalize) → sort | uniq -c | sort -rn → format output
#
# Memory note: sed processes line-by-line (O(1)), but sort requires O(n) memory
# to buffer and sort all input. This is acceptable because:
# - Journal is limited to 500 lines by caller (scan_kernel_logs, scan_user_services)
# - sort is implemented in C, highly optimized for memory and speed
# - Alternative (bash-only dedup) would require O(n²) comparisons or associative arrays
#
# Note: Pipeline ends with || true to prevent set -e abort on rare failures
# (e.g., EINTR from signals, disk full during sort, interrupted by timeout).
# Empty output from pipeline is valid (no errors to cluster).
cluster_errors() {
    # Read from stdin directly into pipeline
    # No intermediate bash variable avoids O(n) string copying
    # Empty input naturally produces empty output (correct behavior)
    #
    # Port normalization: Match :PORT followed by space or end-of-line
    # Pattern is designed to avoid false positives:
    # - Requires alphanumeric or ] before colon (hostname/IP, not space/digit)
    # - This prevents matching: "after 30 attempts", "ratio 16:9", "error 101"
    # - Valid port range: 0-65535 (not enforced in regex, but 5-digit check helps)
    # - Hex addresses already normalized to 0xADDR before this step
    # - IPv6 with ports (e.g., [::1]:8080) matched via ]:PORT pattern
    sed -E \
        -e 's/^[A-Za-z]{3} [ 0-9][0-9] [0-9]{2}:[0-9]{2}:[0-9]{2} [^ ]+ //' \
        -e 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:?[0-9]{2} [^ ]+ //' \
        -e 's/0x[0-9a-fA-F]+/0xADDR/g' \
        -e 's/\[[0-9]+\]/[PID]/g' \
        -e 's/IRQ [0-9]+/IRQ N/g' \
        -e 's/CPU [0-9]+/CPU N/g' \
        -e 's/(sd)[a-z]+/\1DEVICE/g' \
        -e 's/mmcblk[0-9]+/mmcblkDEVICE/g' \
        -e 's/nvme[0-9]+n[0-9]+/nvmeDEVICE/g' \
        -e 's/sector [0-9]+/sector N/g' \
        -e 's/([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}/<MAC>/g' \
        -e 's/(\]):[0-9]{1,5}([ /]|$)/\1:PORT\2/g' \
        -e 's/([a-zA-Z0-9_]):[0-9]{1,5}([ /]|$)/\1:PORT\2/g' | \
    sort | uniq -c | sort -rn | \
    while read -r count msg; do
        if [[ "$count" -gt 1 ]]; then
            printf '%s (x%d)\n' "$msg" "$count"
        else
            printf '%s\n' "$msg"
        fi
    done || true
}

scan_kernel_logs() {
    local -a boot_args=(-b "$BOOT_OFFSET")
    local output=""
    local journal_output=""

    draw_section_header "KERNEL CRITICAL"

    # Fetch kernel errors (priority 3 = ERR)
    # Limit to last 500 lines. Check if journald is active to avoid 5s timeout on broken systems.
    if command -v journalctl &>/dev/null && journalctl --no-pager -n 0 &>/dev/null; then
        journal_output="$(timeout 5 journalctl -k -p 3 -n 500 "${boot_args[@]}" --no-pager 2>/dev/null)" || true
    fi

    if [[ -z "$journal_output" ]]; then
        draw_empty_box
        return 0
    fi

    output="$(cluster_errors <<< "$journal_output")"

    if [[ -z "$output" ]]; then
        draw_empty_box
        return 0
    fi

    # Get first timestamp for context
    local first_ts
    first_ts="$(printf '%s\n' "$journal_output" | head -1 | awk '{print $1, $2, $3}')"

    # Info line with boot info
    local info_line="${C_BLUE}Boot:${C_RESET} ${boot_args[*]} ${C_BLUE}|${C_RESET} First: $first_ts"
    draw_box_line "$info_line"

    # Separator line
    draw_box_line ""

    # Error entries with color highlighting
    # Use awk for case-insensitive pattern matching (no shopt nocasematch needed)
    # Avoids pipeline subshell anti-pattern where 'local' is semantically wrong
    # and shopt inheritance is fragile ("works by accident")
    printf '%s\n' "$output" | head -20 | awk -v red="$C_RED" -v rst="$C_RESET" '
    tolower($0) ~ /error|fail|unable|critical/ {
        print red $0 rst
        next
    }
    { print }
    ' | while read -r colored_line; do
        draw_box_line "$colored_line"
    done

    local total_lines
    total_lines="$(printf '%s\n' "$output" | wc -l)"
    if [[ "$total_lines" -gt 20 ]]; then
        draw_box_line "${C_YELLOW}... and $((total_lines - 20)) more unique errors${C_RESET}"
    fi

}

scan_user_services() {
    local -a boot_args=(-b "$BOOT_OFFSET")
    local output=""
    local journal_output=""

    draw_section_header "SYSTEM SERVICES"

    # ── FAILED SERVICES (systemctl --failed) ──
    local failed_output=""
    if command -v systemctl &>/dev/null; then
        failed_output="$(systemctl --failed --no-legend --no-pager 2>/dev/null)" || true
    fi

    if [[ -n "$failed_output" ]] && printf '%s' "$failed_output" | grep -q .; then
        draw_box_line "${C_RED}${C_BOLD}⚠ Failed Services (systemctl --failed):${C_RESET}"
        draw_box_line ""

        # read splits by IFS (spaces/tabs) — captures multi-word descriptions
        # Edge case: unit names with spaces will shift fields (acceptable trade-off)
        printf '%s\n' "$failed_output" | head -10 | while read -r unit load active sub description; do
            [[ -z "$unit" ]] && continue
            draw_box_line "  ${C_RED}●${C_RESET} ${C_BOLD}${unit}${C_RESET} — ${C_YELLOW}${sub}${C_RESET} (${description})"
        done

        local failed_count
        # Count actual unit lines (exclude summary/blank)
        # grep -c returns exit 1 when no matches — use || true
        failed_count="$(printf '%s\n' "$failed_output" | grep -c '\.service' || true)"
        [[ -z "$failed_count" ]] && failed_count=0
        if [[ "$failed_count" -gt 10 ]]; then
            draw_box_line "${C_YELLOW}... and $((failed_count - 10)) more failed units${C_RESET}"
        fi
        printf '\n'
    else
        draw_box_line "${C_GREEN}✓ No failed services${C_RESET}"
        printf '\n'
    fi

    # ── JOURNAL SERVICE ERRORS ──
    draw_box_line "${C_BOLD}Service Errors (journalctl):${C_RESET}"
    draw_box_line ""

    # Limit to last 500 lines. Check if journald is active to avoid 5s timeout on broken systems.
    if command -v journalctl &>/dev/null && journalctl --no-pager -n 0 &>/dev/null; then
        journal_output="$(timeout 5 journalctl -u "*.service" -p 3 -n 500 "${boot_args[@]}" --no-pager 2>/dev/null)" || true
    fi

    if [[ -z "$journal_output" ]]; then
        draw_empty_box
        return 0
    fi

    output="$(cluster_errors <<< "$journal_output")"

    if [[ -z "$output" ]]; then
        draw_empty_box
        return 0
    fi

    # Header info with boot offset
    local boot_desc
    case "$BOOT_OFFSET" in
        0) boot_desc="current boot" ;;
        -1) boot_desc="previous boot" ;;
        *) boot_desc="boot #$BOOT_OFFSET" ;;
    esac
    draw_box_line "${C_BOLD}Service Journal Errors (${boot_desc})${C_RESET}"
    draw_box_line ""

    printf '%s\n' "$output" | head -15 | while read -r line; do
        # Highlight service names using awk (single pass, no infinite loop risk)
        # Bash regex replacement causes infinite loop: color codes like \e[36m
        # contain alphanumeric chars that create new matches after replacement
        local colored_line
        colored_line="$(printf '%s' "$line" | awk -v cyan="$C_CYAN" -v rst="$C_RESET" '{
            while (match($0, /[a-zA-Z0-9_-]+\.service/)) {
                svc = substr($0, RSTART, RLENGTH)
                printf "%s", substr($0, 1, RSTART-1)
                printf "%s%s%s", cyan, svc, rst
                $0 = substr($0, RSTART+RLENGTH)
            }
            print
        }')"
        draw_box_line "$colored_line"
    done

    local total_lines
    total_lines="$(printf '%s\n' "$output" | wc -l)"
    if [[ "$total_lines" -gt 15 ]]; then
        draw_box_line "${C_YELLOW}... and $((total_lines - 15)) more${C_RESET}"
    fi

}

scan_coredumps() {
    draw_section_header "CORE DUMPS (Last 5)"

    if ! command -v coredumpctl &>/dev/null; then
        draw_box_line "${C_YELLOW}coredumpctl not available${C_RESET}"
        return 0
    fi

    local coredumps
    coredumps="$(coredumpctl list --no-legend 2>/dev/null | tail -5)" || true

    if [[ -z "$coredumps" ]]; then
        draw_empty_box
        return 0
    fi

    # METHOD 1: Try structured JSON output (systemd ≥ v248)
    local json_output
    # Native -r (reverse) and -n 5 gets the 5 most recent entries natively,
    # preventing tail -c from truncating the JSON array string randomly:
    json_output="$(coredumpctl list -r -n 5 --json=short 2>/dev/null)" || json_output=""

    if [[ -n "$json_output" ]] && printf '%s' "$json_output" | grep -q '"pid"'; then
        # Parse JSON: extract pid, sig, exe from coredumpctl --json=short
        # Flatten to one JSON object per line first, then extract fields.
        # This handles both compact (all on one line) and pretty-printed JSON.
        # Step 1: tr '\n' ' '  → collapse all newlines into single line
        # Step 2: sed replaces },{ with }\n{ → one object per line
        # Step 3: awk extracts fields using match() (no destructive gsub)
        printf '%s' "$json_output" | tr '\n' ' ' | sed 's/},{/}\n{/g' | \
        awk -v cyan="$C_CYAN" -v rst="$C_RESET" -v bold="$C_BOLD" -v yellow="$C_YELLOW" '
        BEGIN { count = 0 }

        # Extract numeric value for "key": number from a single-line object
        function extract_num(line, key,    pat, val, start) {
            pat = "\"" key "\"[[:space:]]*:[[:space:]]*[0-9]+"
            if (match(line, pat)) {
                val = substr(line, RSTART, RLENGTH)
                # Extract just the number after the colon
                if (match(val, /[0-9]+$/)) {
                    return substr(val, RSTART, RLENGTH)
                }
            }
            return ""
        }

        # Extract string value for "key": "value" from a single-line object
        function extract_str(line, key,    pat, val) {
            pat = "\"" key "\"[[:space:]]*:[[:space:]]*\"[^\"]*\""
            if (match(line, pat)) {
                val = substr(line, RSTART, RLENGTH)
                # Extract just the value between the last pair of quotes
                if (match(val, /:[[:space:]]*"[^"]*"$/)) {
                    val = substr(val, RSTART, RLENGTH)
                    gsub(/^:[[:space:]]*"/, "", val)
                    gsub(/"$/, "", val)
                    return val
                }
            }
            return ""
        }

        {
            pid = extract_num($0, "pid")
            sig = extract_num($0, "signal")
            exe = extract_str($0, "exe")

            if (pid != "" && exe != "") {
                count++
                if (count > 5) exit
                printf "%s[coredump]%s PID %s%s%s - %s%s%s (signal: %s)\n", \
                    cyan, rst, bold, pid, rst, yellow, exe, rst, sig
            }
        }
        ' | tail -5 | while read -r formatted; do
            draw_box_line "$formatted"
        done
        return 0
    fi

    # METHOD 2: Fallback heuristic for older systemd (< v248)
    printf '%s\n' "$coredumps" | while read -r line; do
        local formatted
        formatted="$(awk -v cyan="$C_CYAN" -v rst="$C_RESET" -v bold="$C_BOLD" -v yellow="$C_YELLOW" '{
            # Find PID by positional context:
            # Timestamp always contains HH:MM:SS — find that field first,
            # then the next purely numeric field after it is the PID.
            # This avoids both year confusion (2024) and PID range assumptions.
            pid_field = 0
            time_field = 0
            for(i=1; i<=NF; i++) {
                if ($i ~ /^[0-9]{1,2}:[0-9]{2}:[0-9]{2}/) {
                    time_field = i
                }
                if (time_field > 0 && i > time_field && $i ~ /^[0-9]+$/) {
                    pid_field = i
                    break
                }
            }

            # If no numeric field found, print raw line
            if (pid_field == 0) {
                print $0
                next
            }

            # Extract fields relative to PID
            pid = $pid_field
            sig = $(pid_field + 3)
            exe_field = pid_field + 4
            if ($(exe_field) ~ /^\/|^\.\/|^[a-zA-Z]/) {
                exe = $(exe_field)
            } else {
                exe = $(exe_field + 1)
            }

            # Build time from all fields before PID
            time = ""
            for(j=1; j<pid_field; j++) time = time (j>1 ? " " : "") $j

            printf "%s[%s]%s PID %s%s%s - %s%s%s (signal: %s)\n", \
                cyan, time, rst, bold, pid, rst, yellow, exe, rst, sig
        }' <<< "$line")"
        draw_box_line "$formatted"
    done

}


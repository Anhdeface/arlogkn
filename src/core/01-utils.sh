# shellcheck shell=bash
# UTILITY FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────

# Get lspci output with caching (single call per session)
# Caches on FIRST SUCCESSFUL call. If lspci fails (timeout, broken PCI bus),
# subsequent calls will retry instead of returning cached empty string.
# This prevents permanent detection failure from transient hardware issues.
# Note: empty output from successful lspci (no PCI devices / VM) is a valid
# cached result — do NOT require -n on _LSPCI_CACHE (causes 5s×N retry loop).
_get_lspci() {
    # Return cached result if available (successful previous call)
    # Only check _LSPCI_CACHE_INIT — empty output is valid (VM, no PCI bus)
    if [[ "$_LSPCI_CACHE_INIT" -eq 1 ]]; then
        printf '%s' "$_LSPCI_CACHE"
        return 0
    fi
    
    # Try to get lspci output
    local lspci_output
    if lspci_output="$(timeout 5 lspci -knn 2>/dev/null)"; then
        # Success: cache result and mark as initialized
        _LSPCI_CACHE="$lspci_output"
        _LSPCI_CACHE_INIT=1
        printf '%s' "$_LSPCI_CACHE"
    else
        # Failure: warn user, return empty, DO NOT mark as initialized
        # This allows retry on next call (transient hardware issues)
        warn "lspci command failed, hardware detection may be incomplete"
        printf ''
    fi
}

die() {
    printf '%s[ERROR]%s %s\n' "${C_RED}" "${C_RESET}" "$1" >&2
    exit 1
}

warn() {
    printf '%s[WARN]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$1" >&2
}

info() {
    printf '%s[INFO]%s %s\n' "${C_BLUE}" "${C_RESET}" "$1"
}

# ─────────────────────────────────────────────────────────────────────────────
# COLOR & TERMINAL DETECTION
# ─────────────────────────────────────────────────────────────────────────────

init_colors() {
    # Disable colors if neither stdout nor stderr is a terminal
    # Rationale:
    # - Main output goes to stdout → check fd 1
    # - warn()/die() messages go to stderr → check fd 2
    # If user runs ./arch-diag.sh > report.txt:
    #   - stdout is file → no colors in main output (correct)
    #   - stderr is terminal → colors in warn/die messages (correct)
    # If BOTH are redirected → no colors anywhere (correct)
    if [[ ! -t 1 ]] && [[ ! -t 2 ]]; then
        C_RESET="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN="" C_BOLD=""
        return 0
    fi

    local colors_avail
    # Check if terminal supports colors (redirect stderr to avoid noise)
    if ! colors_avail=$(tput colors 2>/dev/null) || [[ -z "$colors_avail" ]] || [[ "$colors_avail" -lt 8 ]]; then
        C_RESET="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN="" C_BOLD=""
        return 0
    fi

    # Set color codes (each tput call redirects stderr)
    C_RESET="$(tput sgr0 2>/dev/null)" || C_RESET=""
    C_RED="$(tput setaf 1 2>/dev/null)" || C_RED=""
    C_GREEN="$(tput setaf 2 2>/dev/null)" || C_GREEN=""
    C_YELLOW="$(tput setaf 3 2>/dev/null)" || C_YELLOW=""
    C_BLUE="$(tput setaf 4 2>/dev/null)" || C_BLUE=""
    C_CYAN="$(tput setaf 6 2>/dev/null)" || C_CYAN=""
    C_BOLD="$(tput bold 2>/dev/null)" || C_BOLD=""
}

# ─────────────────────────────────────────────────────────────────────────────
# TABLE DRAWING UTILITIES
# ─────────────────────────────────────────────────────────────────────────────

# Strip ANSI codes (script variables + raw escape sequences)
strip_ansi() {
    local s="$1"
    local var_name="${2:-}"

    # Check if string contains raw ANSI escape sequences
    if [[ "$s" != *$'\x1b'* ]]; then
        # No raw ANSI - just strip script color variables
        s="${s//${C_RED}/}"
        s="${s//${C_GREEN}/}"
        s="${s//${C_YELLOW}/}"
        s="${s//${C_BLUE}/}"
        s="${s//${C_CYAN}/}"
        s="${s//${C_BOLD}/}"
        s="${s//${C_RESET}/}"
        if [[ -n "$var_name" ]]; then
            printf -v "$var_name" '%s' "$s"
        else
            printf '%s' "$s"
        fi
        return 0
    fi

    # String has raw ANSI escape sequences - strip both types
    s="${s//"${C_RED}"/}"
    s="${s//"${C_GREEN}"/}"
    s="${s//"${C_YELLOW}"/}"
    s="${s//"${C_BLUE}"/}"
    s="${s//"${C_CYAN}"/}"
    s="${s//"${C_BOLD}"/}"
    s="${s//"${C_RESET}"/}"

    # Strip raw ANSI escape sequences using sed (single pass, O(n))
    # Handles ALL ANSI escape sequence types:
    # 1. CSI sequences: \x1b[...m (colors, bold, underline, etc.)
    # 2. OSC sequences: \x1b]...BEL (terminal title, hyperlinks, etc.)
    # 3. Other ESC sequences: DCS, APC, PM, SS2, SS3 (rare in logs)
    # Using sed instead of bash loop avoids O(n²) complexity for strings
    # with many ANSI codes (e.g., colored journal errors with 20+ codes)
    # Trade-off: 1 subprocess (~1ms) vs O(n²) bash operations
    s="$(printf '%s' "$s" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b\][^\x07]*\x07//g; s/\x1b[^[]*//g')"

    if [[ -n "$var_name" ]]; then
        printf -v "$var_name" '%s' "$s"
    else
        printf '%s' "$s"
    fi
}

# Get visible length (excluding ANSI codes)
# Calls strip_ansi() which handles both script colors and raw ANSI
#
# PERFORMANCE: Zero-fork implementation for UTF-8 locales.
# Bash 4.0+ ${#var} counts CHARACTERS (not bytes) in UTF-8 locale.
# - "─" (3 bytes) → ${#} returns 1 ✓
# - "✓" (3 bytes) → ${#} returns 1 ✓
# - "Hello" (5 bytes) → ${#} returns 5 ✓
# Only fallback to awk if locale is C/POSIX (rare on modern systems).
#
# Benchmark: awk fork = ~1-2ms per call. With 200-300 calls per scan,
# eliminating forks saves 200-600ms total execution time.
visible_len() {
    local s="$1"
    local var_name="${2:-}"
    local stripped char_count
    strip_ansi "$s" stripped

    # Check if locale supports UTF-8 character counting
    # Most modern systems: UTF-8 locale → ${#var} counts characters correctly
    # Rare C/POSIX locale: ${#var} counts bytes → need awk fallback
    # LC_CTYPE overrides LANG for character classification — must check it too
    # (LC_CTYPE=C with LANG=en_US.UTF-8 → ${#var} counts bytes, not chars)
    local active_lc="${LC_ALL:-${LC_CTYPE:-${LANG:-C}}}"
    if [[ "${active_lc^^}" == *UTF-8* || "${active_lc^^}" == *UTF8* ]]; then
        # Fast path: UTF-8 locale → ${#var} counts characters (not bytes)
        char_count="${#stripped}"
    else
        # Slow path: C/POSIX locale → ${#var} counts bytes, use awk
        char_count=$(awk '{print length}' <<< "$stripped")
    fi

    # Trim whitespace from output
    char_count="${char_count//[[:space:]]/}"
    if [[ -n "$var_name" ]]; then
        printf -v "$var_name" '%d' "$char_count"
    else
        printf '%d' "$char_count"
    fi
}

# Truncate string to N characters (not bytes!) for safe UTF-8 handling
# Usage: truncate_str "string" max_length output_var
# Note: Uses wc -m for character count, not ${#var} which counts bytes.
# This prevents cutting in the middle of multibyte UTF-8 sequences which
# would produce invalid UTF-8 and corrupt terminal display.
truncate_str() {
    local str="$1" max_len="$2" var_name="$3"
    local _truncated

    # Check if locale supports UTF-8 character counting and substring slicing
    # Most modern systems: UTF-8 locale → ${#var} and ${var:0:N} work on characters
    if [[ "${LANG:-C}" != "C" && "${LANG:-C}" != "POSIX" && \
          "${LC_ALL:-}" != "C" && "${LC_ALL:-}" != "POSIX" && \
          "${LC_CTYPE:-}" != "C" && "${LC_CTYPE:-}" != "POSIX" ]]; then
        # Fast path: zero forks
        if [[ "${#str}" -le "$max_len" ]]; then
            _truncated="$str"
        else
            _truncated="${str:0:$max_len}"
        fi
    else
        # Slow path: C/POSIX locale → fallback to wc and cut
        local char_count
        char_count="$(printf '%s' "$str" | wc -m)"
        char_count="${char_count//[[:space:]]/}"
        if [[ "$char_count" -le "$max_len" ]]; then
            _truncated="$str"
        else
            # Use cut -c for character-aware truncation (handles UTF-8 correctly)
            _truncated="$(printf '%s' "$str" | cut -c1-"$max_len")"
        fi
    fi

    if [[ -n "$var_name" ]]; then
        printf -v "$var_name" '%s' "$_truncated"
    else
        printf '%s' "$_truncated"
    fi
}

# Global table state (Stack-managed for re-entrancy)
# WARNING: Table state is stored in global variables. Do NOT call tbl_begin/tbl_row/tbl_end
# from within pipeline subshells (e.g., ... | while read). Subshells cannot modify parent's
# globals, so table state will be lost/corrupted.
# Safe: _gather_temperatures | _format_temperatures_display (entire table in one function)
# Unsafe: tbl_begin ...; cmd | while read; do tbl_row ...; done; tbl_end
#
# MEMORY NOTE: _TBL_COLS_STACK accumulates column definitions for all tables.
# Each tbl_begin appends (2 * num_cols) entries. tbl_end trims the array, but
# if tables are created in a loop without tbl_end, the array grows unboundedly.
# For 100 tables with 5 columns each: 100 * 10 = 1000 array entries.
# This is O(n) memory and O(n) slice operations in tbl_row/tbl_end.
# Mitigation: Maximum table depth limit prevents runaway nesting.
declare -g _TBL_DEPTH=-1
declare -g _TBL_MAX_DEPTH=50  # Maximum nested table depth (prevent unbounded growth)
declare -ga _TBL_WIDTH_STACK=()
declare -ga _TBL_COLS_STACK=()
declare -ga _TBL_COLS_PTR_STACK=()
declare -ga _TBL_NUMCOLS_STACK=()

# Simple table - minimal borders
# Usage: tbl_begin "Col1" width1 "Col2" width2 ...
tbl_begin() {

    # Guard: prevent unbounded _TBL_COLS_STACK growth
    # Each tbl_begin appends (2 * num_cols) entries to global array.
    # Without depth limit, runaway table creation (e.g., in loops) can
    # accumulate thousands of entries, causing O(n) memory and slow slice ops.
    # 50 nested tables is absurdly deep — if hit, it's a bug.
    if [[ "$_TBL_DEPTH" -ge "$_TBL_MAX_DEPTH" ]]; then
        printf '[ERROR] tbl_begin: maximum table depth (%d) exceeded — possible missing tbl_end or runaway loop\n' \
            "$_TBL_MAX_DEPTH" >&2
        return 1
    fi

    _TBL_DEPTH=$((_TBL_DEPTH + 1))
    
    local start_idx=${#_TBL_COLS_STACK[@]}
    _TBL_COLS_PTR_STACK[$_TBL_DEPTH]=$start_idx
    
    local i num_cols=$(($# / 2))
    _TBL_NUMCOLS_STACK[$_TBL_DEPTH]=$num_cols
    
    _TBL_COLS_STACK+=("$@")
    
    local width_sum=0
    local -a args=("$@")
    
    for ((i=0; i<num_cols; i++)); do
        width_sum=$((width_sum + args[i*2+1] + 1))
    done
    _TBL_WIDTH_STACK[$_TBL_DEPTH]=$width_sum
    
    # Header row with simple separator
    printf '%s' "$C_BOLD"
    for ((i=0; i<num_cols; i++)); do
        local name="${args[$((i*2))]}"
        local width="${args[$((i*2+1))]}"
        local vlen pad
        visible_len "$name" vlen
        pad=$((width - vlen))
        printf ' %s%*s' "$name" "$pad" ""
    done
    printf '%s\n' "$C_RESET"
    
    # Simple separator line
    printf '%s' "$C_CYAN"
    for ((i=0; i<width_sum; i++)); do printf '─'; done
    printf '%s\n' "$C_RESET"
}

# Draw a table row
# Usage: tbl_row "val1" "val2" "val3" ...
tbl_row() {
    local -a vals=("$@")
    local start_idx=${_TBL_COLS_PTR_STACK[$_TBL_DEPTH]}
    local num_cols=${_TBL_NUMCOLS_STACK[$_TBL_DEPTH]}

    # Extract the schema for the current table level
    local -a curr_cols=("${_TBL_COLS_STACK[@]:$start_idx:$((num_cols * 2))}")

    local i
    for ((i=0; i<num_cols; i++)); do
        local width="${curr_cols[$((i*2+1))]}"
        local val="${vals[$i]:-}"
        local vlen
        visible_len "$val" vlen
        local display_val="$val"

        # Truncate if too long (strip ANSI for truncation, but lose color)
        # Use truncate_str() for character-aware truncation (handles UTF-8 correctly)
        # ${var:0:N} is byte-index and will corrupt multibyte UTF-8 (box-drawing, emoji, CJK)
        if [[ $vlen -gt $width ]]; then
            local clean truncated
            strip_ansi "$val" clean
            truncate_str "$clean" $((width-3)) truncated
            display_val="${truncated}..."
            vlen=$width
        fi

        local pad=$((width - vlen))
        printf ' %s%*s' "$display_val" "$pad" ""
    done
    printf '\n'
}

# Close table
tbl_end() {
    # Guard: prevent underflow if tbl_end() called without matching tbl_begin()
    # This can happen from coding errors (extra tbl_end, missing tbl_begin)
    # In a 4000+ line script with 100+ call sites, silent no-op is a bug attractor
    if (( _TBL_DEPTH < 0 )); then
        warn "tbl_end() called without matching tbl_begin() — table stack underflow prevented"
        return 1
    fi

    local start_idx=${_TBL_COLS_PTR_STACK[$_TBL_DEPTH]}
    if (( start_idx == 0 )); then
        _TBL_COLS_STACK=()
    else
        _TBL_COLS_STACK=("${_TBL_COLS_STACK[@]:0:$start_idx}")
    fi

    unset '_TBL_WIDTH_STACK[_TBL_DEPTH]'
    unset '_TBL_COLS_PTR_STACK[_TBL_DEPTH]'
    unset '_TBL_NUMCOLS_STACK[_TBL_DEPTH]'
    _TBL_DEPTH=$((_TBL_DEPTH - 1))
}

# Legacy wrappers for backward compatibility (102 call sites use these names)
draw_table_begin() { tbl_begin "$@"; }
draw_table_row() { tbl_row "$@"; }
# shellcheck disable=SC2120
draw_table_end() { tbl_end "$@"; }
draw_table_header() { tbl_begin "$@"; }
# shellcheck disable=SC2120
draw_table_footer() { tbl_end "$@"; }

# ─────────────────────────────────────────────────────────────────────────────

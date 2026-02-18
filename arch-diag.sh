#!/usr/bin/env bash
# file: arch-diag.sh
# arlogkn - Read-only diagnostic tool
# Dependencies: bash 5.0+, coreutils, util-linux, systemd, awk, sed, grep

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# GLOBALS & CONFIG
# ─────────────────────────────────────────────────────────────────────────────
readonly VERSION="1.0.0"
readonly SCRIPT_NAME="$(basename "$0")"

# Color state (set dynamically)
declare -i COLOR_SUPPORT=1
declare -g C_RESET="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN="" C_BOLD=""

# Scan scope
declare -g SCAN_KERNEL=0
declare -g SCAN_USER=0
declare -g SCAN_ALL=1
declare -g SCAN_MOUNT=0
declare -g SCAN_USB=0
declare -g SCAN_DRIVER=0
declare -g SCAN_VGA=0
declare -g SCAN_SYSTEM=0
declare -g SCAN_WIKI=0
declare -g WIKI_GROUP=""
declare -g BOOT_OFFSET=0
declare -g SAVE_LOGS=0
declare -g SAVE_ALL=0
declare -g INTERNET_STATUS="unknown"

# Output directory for saved logs
declare -g OUTPUT_DIR="./arch-diag-logs"

# Table formatting
declare -g TABLE_WIDTH=66

# Distro info
declare -g DISTRO_NAME="Unknown"
declare -g DISTRO_TYPE="Generic"
declare -g KERNEL_VER=""
declare -g CPU_GOVERNOR="unknown"
declare -g GPU_INFO=""
declare -g DISPLAY_INFO=""

# ─────────────────────────────────────────────────────────────────────────────
# UTILITY FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────

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
    local colors_avail
    # Check if terminal supports colors (redirect stderr to avoid noise)
    if ! colors_avail=$(tput colors 2>/dev/null) || [[ -z "$colors_avail" ]] || [[ "$colors_avail" -lt 8 ]]; then
        COLOR_SUPPORT=0
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
# DISTRO & SYSTEM FINGERPRINTING
# ─────────────────────────────────────────────────────────────────────────────

detect_distro() {
    local id="" variant=""

    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        id="$(grep -E '^ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')"
        variant="$(grep -E '^ID_LIKE=' /etc/os-release | cut -d'=' -f2 | tr -d '"' || echo "")"
    elif [[ -f /etc/arch-release ]]; then
        id="arch"
    else
        id="unknown"
    fi

    case "$id" in
        cachyos)
            DISTRO_NAME="CachyOS"
            DISTRO_TYPE="Performance Tuned"
            ;;
        arch)
            DISTRO_NAME="Arch Linux"
            DISTRO_TYPE="Pure Arch"
            ;;
        manjaro*|endeavouros*)
            DISTRO_NAME="$(echo "$id" | sed 's/.*/\u&/')"
            DISTRO_TYPE="Arch-based"
            ;;
        *)
            if [[ "$variant" == *"arch"* ]]; then
                DISTRO_NAME="Arch-based Generic"
                DISTRO_TYPE="Derivative"
            else
                DISTRO_NAME="Unknown (ID: $id)"
                DISTRO_TYPE="Unverified"
            fi
            ;;
    esac
}

detect_system_info() {
    KERNEL_VER="$(uname -r)"

    # CPU Governor detection (may require root for full accuracy)
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
        CPU_GOVERNOR="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")"
    elif command -v cpupower &>/dev/null; then
        CPU_GOVERNOR="$(cpupower frequency-info 2>/dev/null | grep -oP 'current policy:.*?\K\w+' | head -1 || echo "unknown")"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# HARDWARE & SYSTEM DETECTION
# ─────────────────────────────────────────────────────────────────────────────

check_internet() {
    # Check internet connection
    if command -v ping &>/dev/null; then
        if ping -c1 -W2 8.8.8.8 &>/dev/null; then
            INTERNET_STATUS="connected"
            return 0
        fi
    elif command -v curl &>/dev/null; then
        if curl -s --connect-timeout 2 https://www.google.com &>/dev/null; then
            INTERNET_STATUS="connected"
            return 0
        fi
    fi
    INTERNET_STATUS="disconnected"
    return 1
}

detect_gpu() {
    # Optimized GPU detection for Arch Linux
    # Try /sys filesystem first (lightweight, no external deps)
    local gpu_names=()
    local card_path driver gpu_name

    # Check all DRM cards (supports multiple GPUs, e.g., hybrid graphics)
    shopt -s nullglob
    for card_path in /sys/class/drm/card*; do
        [[ ! -d "$card_path" ]] && continue
        
        # Skip render nodes (they're symlinks to cards)
        [[ "$card_path" == *"render"* ]] && continue
        
        driver=""
        if [[ -L "${card_path}/device/driver" ]]; then
            driver="$(readlink "${card_path}/device/driver" 2>/dev/null | xargs basename 2>/dev/null)"
        fi

        case "$driver" in
            nvidia) gpu_name="NVIDIA GPU (proprietary)" ;;
            nvidia-drm) gpu_name="NVIDIA GPU (DRM)" ;;
            amdgpu) gpu_name="AMD GPU (amdgpu)" ;;
            radeon) gpu_name="AMD GPU (radeon)" ;;
            i915) gpu_name="Intel Integrated Graphics" ;;
            xe) gpu_name="Intel Xe Graphics" ;;
            nouveau) gpu_name="NVIDIA GPU (nouveau)" ;;
            virtio_gpu) gpu_name="Virtual GPU (virtio)" ;;
            vmwgfx) gpu_name="VMware Virtual GPU" ;;
            *) gpu_name="" ;;
        esac
        
        # Add to list if detected
        [[ -n "$gpu_name" ]] && gpu_names+=("$gpu_name")
    done
    shopt -u nullglob

    # Build GPU info string (supports multiple GPUs)
    if [[ ${#gpu_names[@]} -gt 0 ]]; then
        # Remove duplicates and join with ", "
        GPU_INFO="$(printf '%s\n' "${gpu_names[@]}" | sort -u | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')"
    else
        GPU_INFO=""
    fi

    # Fallback to lspci if available and no GPU detected yet
    if [[ -z "$GPU_INFO" ]] && command -v lspci &>/dev/null; then
        GPU_INFO="$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | head -1 | cut -d':' -f3- | sed 's/^ *//')"
    fi

    # Final fallback to lshw
    if [[ -z "$GPU_INFO" ]] && command -v lshw &>/dev/null; then
        GPU_INFO="$(lshw -class display 2>/dev/null | grep -m1 'product:' | cut -d':' -f2 | sed 's/^ *//')"
    fi

    GPU_INFO="${GPU_INFO:-Unknown}"
}

detect_display() {
    # Optimized display detection for Arch Linux (works with/without X11)
    local connector status
    
    # Check DRM connectors directly from /sys (works without X11/Wayland)
    shopt -s nullglob
    for connector in /sys/class/drm/card*/card*-*/status; do
        [[ ! -f "$connector" ]] && continue
        status="$(cat "$connector" 2>/dev/null)"
        if [[ "$status" == "connected" ]]; then
            local name
            name="$(basename "$(dirname "$connector")")"
            name="${name#card*-}"  # Remove "card*-" prefix

            # Get resolution if available
            local res=""
            local modes_file
            for modes_file in /sys/class/drm/card*/card*-*/modes; do
                if [[ -f "$modes_file" ]]; then
                    res="$(cat "$modes_file" 2>/dev/null | head -1)"
                    break
                fi
            done

            DISPLAY_INFO="${name} connected"
            [[ -n "$res" ]] && DISPLAY_INFO="$DISPLAY_INFO ($res)"
            shopt -u nullglob
            return 0
        fi
    done
    shopt -u nullglob

    # Fallback: check if any DRM device exists
    if ls /sys/class/drm/card* &>/dev/null; then
        DISPLAY_INFO="DRM active (no connected display)"
        return 0
    fi

    DISPLAY_INFO="No display detected"
}

detect_drivers() {
    # Get loaded kernel drivers/modules count
    local loaded_count
    loaded_count="$(lsmod 2>/dev/null | wc -l)"
    
    # Check for common driver categories
    local gpu_driver="N/A"
    local network_driver="N/A"
    local audio_driver="N/A"
    
    if command -v lspci &>/dev/null; then
        gpu_driver="$(lspci -k 2>/dev/null | grep -A2 -i 'vga\|3d' | grep 'Kernel driver' | head -1 | cut -d':' -f2 | sed 's/^ *//')"
        network_driver="$(lspci -k 2>/dev/null | grep -A2 -i 'ethernet\|network' | grep 'Kernel driver' | head -1 | cut -d':' -f2 | sed 's/^ *//')"
        audio_driver="$(lspci -k 2>/dev/null | grep -A2 -i 'audio' | grep 'Kernel driver' | head -1 | cut -d':' -f2 | sed 's/^ *//')"
    fi
    
    [[ -z "$gpu_driver" ]] && gpu_driver="N/A"
    [[ -z "$network_driver" ]] && network_driver="N/A"
    [[ -z "$audio_driver" ]] && audio_driver="N/A"
    
    printf '%s|%s|%s|%s' "$loaded_count" "$gpu_driver" "$network_driver" "$audio_driver"
}

# ─────────────────────────────────────────────────────────────────────────────
# UI / BOX DRAWING
# ─────────────────────────────────────────────────────────────────────────────

# Note: strip_ansi and visible_len are defined in TABLE section below

draw_header() {
    local title="$1"
    local width="${2:-70}"
    local title_visible_len
    title_visible_len="$(visible_len "$title")"
    local padding=$((width - title_visible_len - 2))
    local right_pad=$((padding / 2))
    local left_pad=$((padding - right_pad))

    # Top border line
    printf '%s' "$C_CYAN"
    for ((i=0; i<width; i++)); do printf '─'; done
    printf '%s\n' "$C_RESET"

    # Title line
    printf '%s%*s' "$C_BOLD" "$left_pad" ""
    printf '%s%s' "$title" "$C_RESET"
    printf '%*s\n' "$right_pad" ""

    # Bottom border line
    printf '%s' "$C_CYAN"
    for ((i=0; i<width; i++)); do printf '─'; done
    printf '%s\n' "$C_RESET"
}

draw_section_header() {
    local title="$1"
    printf '\n%s──[ %s ]%s\n' "$C_CYAN" "$title" "$C_RESET"
}

draw_box_line() {
    local content="$1"
    local width="${2:-70}"
    local inner_width=$((width - 4))
    local content_visible_len
    content_visible_len="$(visible_len "$content")"

    # Truncate if too long
    if [[ $content_visible_len -gt $inner_width ]]; then
        local truncate_at=$((inner_width - 3))
        local stripped
        stripped="$(strip_ansi "$content")"
        content="${stripped:0:$truncate_at}..."
        content_visible_len=$((truncate_at + 3))
    fi

    local padding=$((inner_width - content_visible_len))
    if [[ $padding -lt 0 ]]; then
        padding=0
    fi

    printf ' %s %*s\n' "$content" "$padding" ""
}

draw_empty_box() {
    local width="${1:-70}"
    local message="✓ No Critical Issues Found"
    local msg_len=26
    local padding=$((width - msg_len))
    local half_pad=$((padding / 2))
    local remainder=$((padding - half_pad))

    printf '%*s%s%s%s%*s\n' "$half_pad" "" "$C_GREEN" "$message" "$C_RESET" "$remainder" ""
}

draw_footer() {
    : # No-op - removed for clean look
}

draw_info_box() {
    local label="$1"
    local value="$2"
    local width="${3:-70}"
    local inner_width=$((width - 4))
    local full_line="$label: $value"
    local full_visible_len
    full_visible_len="$(visible_len "$full_line")"
    local padding=$((inner_width - full_visible_len))

    if [[ $padding -lt 0 ]]; then
        padding=0
    fi

    printf ' %s%s%*s\n' "$C_BOLD" "$full_line" "$padding" "" "$C_RESET"
}

# ─────────────────────────────────────────────────────────────────────────────
# TABLE DRAWING UTILITIES (Clean, minimal borders, ANSI-aware)
# ─────────────────────────────────────────────────────────────────────────────

# Strip ANSI codes (bash-only, no external deps)
strip_ansi() {
    local s="$1"
    s="${s//${C_RED}/}"
    s="${s//${C_GREEN}/}"
    s="${s//${C_YELLOW}/}"
    s="${s//${C_BLUE}/}"
    s="${s//${C_CYAN}/}"
    s="${s//${C_BOLD}/}"
    s="${s//${C_RESET}/}"
    printf '%s' "$s"
}

# Get visible length (excluding ANSI codes)
visible_len() {
    local s
    s=$(strip_ansi "$1")
    printf '%d' "${#s}"
}

# Global table state
declare -g _TBL_WIDTH=0
declare -ga _TBL_COLS=()

# Simple table - minimal borders
# Usage: tbl_begin "Col1" width1 "Col2" width2 ...
tbl_begin() {
    _TBL_COLS=("$@")
    _TBL_WIDTH=0
    
    local i num_cols=$((${#_TBL_COLS[@]} / 2))
    for ((i=0; i<num_cols; i++)); do
        _TBL_WIDTH=$((_TBL_WIDTH + ${_TBL_COLS[$((i*2+1))]} + 2))
    done
    
    # Header row with simple separator
    printf '%s' "$C_BOLD"
    for ((i=0; i<num_cols; i++)); do
        local name="${_TBL_COLS[$((i*2))]}"
        local width="${_TBL_COLS[$((i*2+1))]}"
        local vlen=${#name}
        local pad=$((width - vlen))
        printf ' %s%*s' "$name" "$pad" ""
    done
    printf '%s\n' "$C_RESET"
    
    # Simple separator line
    printf '%s' "$C_CYAN"
    for ((i=0; i<_TBL_WIDTH; i++)); do printf '─'; done
    printf '%s\n' "$C_RESET"
}

# Draw a table row
# Usage: tbl_row "val1" "val2" "val3" ...
tbl_row() {
    local -a vals=("$@")
    local num_cols=$((${#_TBL_COLS[@]} / 2))
    local i
    
    for ((i=0; i<num_cols; i++)); do
        local width="${_TBL_COLS[$((i*2+1))]}"
        local val="${vals[$i]:-}"
        local vlen
        vlen=$(visible_len "$val")
        local clean
        clean=$(strip_ansi "$val")
        
        # Truncate if too long
        if [[ $vlen -gt $width ]]; then
            clean="${clean:0:$((width-3))}..."
            vlen=$width
        fi
        
        local pad=$((width - vlen))
        printf ' %s%*s' "$clean" "$pad" ""
    done
    printf '\n'
}

# Close table - no footer needed for minimal style
tbl_end() {
    : # No-op for clean look
}

# Legacy wrappers
draw_table_begin() { tbl_begin "$@"; }
draw_table_row() { tbl_row "$@"; }
draw_table_end() { tbl_end "$@"; }
draw_table_header() { tbl_begin "$@"; }
draw_table_footer() { tbl_end "$@"; }

# ─────────────────────────────────────────────────────────────────────────────
# LOG PARSING ENGINE
# ─────────────────────────────────────────────────────────────────────────────

# Cluster identical errors and count occurrences
cluster_errors() {
    local input="$1"

    if [[ -z "$input" ]]; then
        return 1
    fi

    # Normalize: extract message, count duplicates
    printf '%s\n' "$input" | \
        sed -E 's/^[A-Za-z]{3} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [^ ]+ //' | \
        sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4} [^ ]+ //' | \
        sort | uniq -c | sort -rn | \
        while read -r count msg; do
            if [[ "$count" -gt 1 ]]; then
                printf '%s (x%d)\n' "$msg" "$count"
            else
                printf '%s\n' "$msg"
            fi
        done
}

scan_kernel_logs() {
    local boot_flag="$1"
    local output=""
    local journal_output=""

    draw_section_header "KERNEL CRITICAL"

    # Check journal accessibility (not integrity - that requires root)
    if ! journalctl -n 1 --quiet 2>/dev/null; then
        warn "Cannot access system journal (try running as root for full access)"
    fi

    # Fetch kernel errors (priority 3 = ERR)
    journal_output="$(journalctl -k -p 3 "$boot_flag" --no-pager 2>/dev/null)" || true

    if [[ -z "$journal_output" ]] || ! printf '%s' "$journal_output" | grep -q .; then
        draw_empty_box
        return 0
    fi

    output="$(cluster_errors "$journal_output")"

    if [[ -z "$output" ]]; then
        draw_empty_box
        return 0
    fi

    # Get first timestamp for context
    local first_ts
    first_ts="$(printf '%s\n' "$journal_output" | head -1 | awk '{print $1, $2, $3}')"

    # Info line with boot info
    local info_line="${C_BLUE}Boot:${C_RESET} ${boot_flag:--b $BOOT_OFFSET} ${C_BLUE}|${C_RESET} First: $first_ts"
    draw_box_line "$info_line"

    # Separator line
    printf '%s%*s\n' "$C_CYAN" 64 "" "$C_RESET"

    # Error entries with color highlighting
    printf '%s\n' "$output" | head -20 | while read -r line; do
        # Highlight error patterns with red
        local colored_line="$line"
        if [[ "$line" =~ [Ee]rror|[Ff]ail|[Uu]nable|[Cc]ritical ]]; then
            colored_line="${C_RED}${line}${C_RESET}"
        fi
        draw_box_line "$colored_line"
    done

    local total_lines
    total_lines="$(printf '%s\n' "$output" | wc -l)"
    if [[ "$total_lines" -gt 20 ]]; then
        draw_box_line "${C_YELLOW}... and $((total_lines - 20)) more unique errors${C_RESET}"
    fi

    draw_footer
}

scan_user_services() {
    local boot_flag="$1"
    local output=""
    local journal_output=""

    draw_section_header "SYSTEM SERVICES"

    journal_output="$(journalctl -u "*.service" -p 3 "$boot_flag" --no-pager 2>/dev/null)" || true

    if [[ -z "$journal_output" ]] || ! printf '%s' "$journal_output" | grep -q .; then
        draw_empty_box
        return 0
    fi

    output="$(cluster_errors "$journal_output")"

    if [[ -z "$output" ]]; then
        draw_empty_box
        return 0
    fi

    # Header info
    draw_box_line "${C_BOLD}Failed services (current boot)${C_RESET}"
    printf '%s%*s\n' "$C_CYAN" 64 "" "$C_RESET"

    printf '%s\n' "$output" | head -15 | while read -r line; do
        # Highlight service names
        local colored_line
        colored_line="$(echo "$line" | sed -E "s/([a-zA-Z0-9_-]+\.service)/${C_CYAN}\1${C_RESET}/g")"
        draw_box_line "$colored_line"
    done

    local total_lines
    total_lines="$(printf '%s\n' "$output" | wc -l)"
    if [[ "$total_lines" -gt 15 ]]; then
        draw_box_line "${C_YELLOW}... and $((total_lines - 15)) more${C_RESET}"
    fi

    draw_footer
}

scan_coredumps() {
    draw_section_header "CORE DUMPS (Last 5)"

    if ! command -v coredumpctl &>/dev/null; then
        draw_box_line "${C_YELLOW}coredumpctl not available${C_RESET}"
        draw_footer
        return 0
    fi

    local coredumps
    coredumps="$(coredumpctl list --no-legend 2>/dev/null | tail -5)" || true

    if [[ -z "$coredumps" ]]; then
        draw_empty_box
        return 0
    fi

    printf '%s\n' "$coredumps" | while read -r line; do
        # Parse coredumpctl output: TIME PID UID GID SIG COREFILE EXE
        local time pid exe size
        time="$(echo "$line" | awk '{print $1, $2}')"
        pid="$(echo "$line" | awk '{print $3}')"
        size="$(echo "$line" | awk '{print $(NF-1)}')"
        exe="$(echo "$line" | awk '{print $NF}')"
        draw_box_line "${C_CYAN}[$time]${C_RESET} PID ${C_BOLD}$pid${C_RESET} - ${C_YELLOW}$exe${C_RESET} ($size)"
    done

    draw_footer
}

scan_pacman_logs() {
    draw_section_header "PACMAN / ALPM (Errors & Warnings)"

    local pacman_log="/var/log/pacman.log"

    if [[ ! -f "$pacman_log" ]]; then
        draw_box_line "${C_YELLOW}Pacman log not found (may require root)${C_RESET}"
        draw_footer
        return 0
    fi

    # Read last 100 lines, filter errors/warnings, show last 10
    local issues
    issues="$(tail -100 "$pacman_log" 2>/dev/null | grep -iE '(error|warning)' | grep -v '^#' | tail -10)" || true

    if [[ -z "$issues" ]]; then
        draw_empty_box
        return 0
    fi

    printf '%s\n' "$issues" | while read -r line; do
        # Sanitize: remove potential ANSI/binary garbage
        line="$(printf '%s' "$line" | tr -cd '[:print:]\t')"
        # Color-code based on severity
        local colored_line="$line"
        if [[ "$line" =~ [Ee][Rr][Rr][Oo][Rr] ]]; then
            colored_line="${C_RED}${line}${C_RESET}"
        elif [[ "$line" =~ [Ww][Aa][Rr][Nn][Ii][Nn][Gg] ]]; then
            colored_line="${C_YELLOW}${line}${C_RESET}"
        fi
        draw_box_line "$colored_line"
    done

    draw_footer
}

# ─────────────────────────────────────────────────────────────────────────────
# MOUNT & USB SCANNING (Optimized for Arch Linux)
# ─────────────────────────────────────────────────────────────────────────────

scan_mounts() {
    draw_section_header "MOUNTED FILESYSTEMS"
    printf '\n'

    # Cache df output once for size lookup (efficient)
    declare -A df_sizes
    while IFS=' ' read -r fs size rest; do
        if [[ -n "$fs" && "$size" =~ ^[0-9]+$ ]]; then
            # Convert KB to human-readable
            if [[ $size -ge 1073741824 ]]; then
                df_sizes["$fs"]="$((size / 1073741824))T"
            elif [[ $size -ge 1048576 ]]; then
                df_sizes["$fs"]="$((size / 1048576))G"
            elif [[ $size -ge 1024 ]]; then
                df_sizes["$fs"]="$((size / 1024))M"
            else
                df_sizes["$fs"]="${size}K"
            fi
        fi
    done < <(df -P 2>/dev/null | tail -n +2)

    # Table header
    draw_table_begin "Device" 22 "Mountpoint" 24 "Type" 12 "Size" 10

    # Use /proc/mounts directly (lightweight, no external deps)
    local count=0
    while IFS=' ' read -r source target fstype opts freq pass; do
        [[ $count -ge 12 ]] && break
        [[ "$source" =~ ^# ]] && continue
        [[ "$fstype" == "autofs" ]] && continue
        
        # Get size from df cache
        local size="${df_sizes[$source]:-N/A}"
        local color="$C_RESET"
        
        case "$fstype" in
            ext4|btrfs|xfs) color="$C_GREEN" ;;
            nfs|cifs) color="$C_YELLOW" ;;
            tmpfs|devtmpfs) color="$C_BLUE" ;;
            overlay|squashfs) color="$C_CYAN" ;;
        esac
        
        draw_table_row "${color}${source}${C_RESET}" "${target}" "${fstype}" "${size}"
        count=$((count + 1))
    done < /proc/mounts

    draw_table_end

    # Disk usage - use df with minimal output
    draw_section_header "DISK USAGE"
    draw_table_begin "Filesystem" 24 "Size" 9 "Used" 9 "Avail" 9 "Use%" 6

    df -h 2>/dev/null | awk 'NR>1 && /^\/dev\// {print $1"|"$2"|"$3"|"$4"|"$5}' | sort -u | head -6 | while IFS='|' read -r fs size used avail usep; do
        local color="$C_RESET"
        local use_num="${usep%\%}"
        [[ "$use_num" -gt 90 ]] && color="$C_RED"
        [[ "$use_num" -gt 70 && "$use_num" -le 90 ]] && color="$C_YELLOW"
        draw_table_row "${color}${fs}${C_RESET}" "$size" "$used" "$avail" "$usep"
    done

    draw_table_end
}

scan_usb_devices() {
    draw_section_header "USB DEVICES"
    printf '\n'

    # Check USB subsystem via /sys (no external deps)
    if [[ ! -d /sys/bus/usb/devices ]]; then
        draw_box_line "${C_YELLOW}USB subsystem not available${C_RESET}"
        draw_footer
        return 0
    fi

    # Table header
    draw_table_begin "Vendor" 10 "Product" 30 "Bus/Dev" 8 "Type" 8

    # Use /sys filesystem directly (lightweight, works without lsusb)
    local count=0
    for dev_path in /sys/bus/usb/devices/*; do
        [[ $count -ge 10 ]] && break
        
        # Skip broken symlinks
        [[ -L "$dev_path" && ! -e "$dev_path" ]] && continue
        
        # Skip if not a directory (after resolving symlinks)
        [[ ! -d "$dev_path" ]] && continue

        local dev_name
        dev_name="$(basename "$dev_path")"

        # Skip root hubs (they start with usb)
        [[ "$dev_name" == usb* ]] && continue

        # Skip if no idVendor - means it's a hub or invalid device
        [[ ! -f "$dev_path/idVendor" ]] && continue

        local product="" vendor="" dev_id="" bus_id="" manufacturer=""

        # Read from sysfs (no external commands)
        vendor="$(cat "$dev_path/idVendor" 2>/dev/null || echo "")"
        [[ -z "$vendor" ]] && continue  # Skip if no vendor ID
        
        dev_id="$(cat "$dev_path/devnum" 2>/dev/null || echo "?")"
        bus_id="$(cat "$dev_path/busnum" 2>/dev/null || echo "?")"
        
        # Try product first, then manufacturer as fallback
        product="$(cat "$dev_path/product" 2>/dev/null || echo "")"
        if [[ -z "$product" || "$product" =~ ^[[:cntrl:]]*$ ]]; then
            manufacturer="$(cat "$dev_path/manufacturer" 2>/dev/null || echo "")"
            [[ -n "$manufacturer" && ! "$manufacturer" =~ ^[[:cntrl:]]*$ ]] && product="$manufacturer"
        fi
        
        # Clean product name (remove control characters)
        product="$(echo "$product" | tr -d '[:cntrl:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        
        # Fallback product name
        [[ -z "$product" ]] && product="USB Device"
        
        # Determine device type from product name
        local dev_type="Other"
        case "$product" in
            *Keyboard*) dev_type="Keyboard" ;;
            *Mouse*) dev_type="Mouse" ;;
            *Hub*) dev_type="Hub" ;;
            *Storage*|*Flash*|*Disk*|*Mass*|*SD*|*Card*) dev_type="Storage" ;;
            *Webcam*|*Camera*) dev_type="Camera" ;;
            *Controller*|*Receiver*|*Wireless*|*Dongle*) dev_type="Controller" ;;
            *Audio*|*Headset*|*Speaker*|*Headphone*) dev_type="Audio" ;;
        esac

        draw_table_row "${vendor}:????" "${product:0:29}" "Bus ${bus_id}" "$dev_type"
        count=$((count + 1))
    done

    draw_table_end

    # USB storage - check via /sys/block (no lsblk needed)
    draw_section_header "USB STORAGE"

    local found_storage=0
    draw_table_begin "Device" 8 "Size" 10 "Model" 20 "Mount" 18

    for block in /sys/block/*; do
        [[ ! -d "$block" ]] && continue
        local bname
        bname="$(basename "$block")"
        
        # Check if it's a USB device (sd* or mmc*)
        [[ ! "$bname" =~ ^(sd[a-z]|mmcblk[0-9])$ ]] && continue
        
        # Check if removable (USB drives are removable)
        local removable="0"
        [[ -f "$block/removable" ]] && removable="$(cat "$block/removable" 2>/dev/null)"
        [[ "$removable" != "1" ]] && continue
        
        found_storage=1
        local size="?" model="" mount=""
        
        [[ -f "$block/size" ]] && size="$(cat "$block/size" 2>/dev/null)"
        [[ -n "$size" && "$size" != "?" ]] && size="$((size / 2 / 1024 / 1024))Gi"
        
        [[ -f "$block/device/vendor" ]] && model="$(cat "$block/device/vendor" 2>/dev/null)"
        [[ -f "$block/device/model" ]] && model="$model $(cat "$block/device/model" 2>/dev/null)"
        [[ -z "$model" ]] && model="USB Storage"
        
        # Check mount point from /proc/mounts
        mount="$(grep "^/dev/${bname}" /proc/mounts 2>/dev/null | awk '{print $2}' | head -1)"
        [[ -z "$mount" ]] && mount="<unmounted>"
        
        draw_table_row "/dev/${bname}" "$size" "${model:0:19}" "${mount:0:17}"
    done
    
    if [[ $found_storage -eq 0 ]]; then
        printf ' %s✓ No USB storage devices detected%s\n' "$C_GREEN" "$C_RESET"
    fi

    draw_table_end
}

# ─────────────────────────────────────────────────────────────────────────────
# VGA / GPU & DRIVER SCANNING (Optimized for Arch Linux)
# ─────────────────────────────────────────────────────────────────────────────

scan_vga_info() {
    draw_section_header "GPU / VGA INFORMATION"
    printf '\n'

    # GPU Info from lspci or /sys
    draw_box_line "${C_BOLD}Graphics Card:${C_RESET}"
    draw_box_line " ${C_CYAN}${GPU_INFO}${C_RESET}"
    printf '\n'

    # Display info - optimized detection
    draw_box_line "${C_BOLD}Display:${C_RESET}"
    draw_box_line " ${C_CYAN}${DISPLAY_INFO}${C_RESET}"
    printf '\n'

    # OpenGL info (only if glxinfo available - from mesa-utils)
    if command -v glxinfo &>/dev/null; then
        local glx_vendor glx_renderer
        glx_vendor="$(glxinfo -s 2>/dev/null | grep 'OpenGL vendor' | cut -d':' -f2 | sed 's/^ *//')"
        glx_renderer="$(glxinfo -s 2>/dev/null | grep 'OpenGL renderer' | cut -d':' -f2 | sed 's/^ *//')"
        
        [[ -n "$glx_vendor" ]] && draw_box_line "${C_BOLD}OpenGL Vendor:${C_RESET} ${C_CYAN}${glx_vendor}${C_RESET}"
        [[ -n "$glx_renderer" ]] && draw_box_line "${C_BOLD}OpenGL Renderer:${C_RESET} ${C_CYAN}${glx_renderer}${C_RESET}"
    fi

    printf '\n'
}

scan_drivers() {
    draw_section_header "DRIVER STATUS"
    printf '\n'

    local drivers_info
    drivers_info="$(detect_drivers)"
    
    local loaded_count gpu_drv net_drv audio_drv
    loaded_count="$(echo "$drivers_info" | cut -d'|' -f1)"
    gpu_drv="$(echo "$drivers_info" | cut -d'|' -f2)"
    net_drv="$(echo "$drivers_info" | cut -d'|' -f3)"
    audio_drv="$(echo "$drivers_info" | cut -d'|' -f4)"

    # Loaded modules count
    draw_box_line "${C_BOLD}Loaded Kernel Modules:${C_RESET} ${C_CYAN}${loaded_count}${C_RESET}"
    printf '\n'

    # Driver table
    draw_table_begin "Category" 15 "Driver" 45 "Status" 10
    tbl_row "GPU" "${gpu_drv}" "$([[ "$gpu_drv" != "N/A" ]] && echo "${C_GREEN}Active${C_RESET}" || echo "${C_YELLOW}N/A${C_RESET}")"
    tbl_row "Network" "${net_drv}" "$([[ "$net_drv" != "N/A" ]] && echo "${C_GREEN}Active${C_RESET}" || echo "${C_YELLOW}N/A${C_RESET}")"
    tbl_row "Audio" "${audio_drv}" "$([[ "$audio_drv" != "N/A" ]] && echo "${C_GREEN}Active${C_RESET}" || echo "${C_YELLOW}N/A${C_RESET}")"
    draw_table_end

    printf '\n'
}

scan_system_basics() {
    draw_section_header "SYSTEM INFORMATION"
    printf '\n'

    # Internet status
    local internet_icon
    if [[ "$INTERNET_STATUS" == "connected" ]]; then
        internet_icon="${C_GREEN}✓ Connected${C_RESET}"
    else
        internet_icon="${C_RED}✗ Disconnected${C_RESET}"
    fi
    draw_box_line "${C_BOLD}Internet:${C_RESET} ${internet_icon}"

    # CPU info
    local cpu_model
    cpu_model="$(grep 'model name' /proc/cpuinfo 2>/dev/null | head -1 | cut -d':' -f2 | sed 's/^ *//')"
    [[ -z "$cpu_model" ]] && cpu_model="Unknown"
    draw_box_line "${C_BOLD}CPU:${C_RESET} ${cpu_model}"

    # CPU cores
    local cpu_cores
    cpu_cores="$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo "?")"
    draw_box_line "${C_BOLD}CPU Cores:${C_RESET} ${cpu_cores}"

    # RAM
    local ram_total ram_used ram_avail
    if command -v free &>/dev/null; then
        ram_total="$(free -h 2>/dev/null | awk '/^Mem:/ {print $2}')"
        ram_used="$(free -h 2>/dev/null | awk '/^Mem:/ {print $3}')"
        ram_avail="$(free -h 2>/dev/null | awk '/^Mem:/ {print $7}')"
        draw_box_line "${C_BOLD}RAM:${C_RESET} Total: ${ram_total} | Used: ${ram_used} | Available: ${ram_avail}"
    fi

    # Disk
    local disk_total disk_used disk_avail
    if command -v df &>/dev/null; then
        local root_info
        root_info="$(df -h / 2>/dev/null | tail -1)"
        disk_total="$(echo "$root_info" | awk '{print $2}')"
        disk_used="$(echo "$root_info" | awk '{print $3}')"
        disk_avail="$(echo "$root_info" | awk '{print $4}')"
        draw_box_line "${C_BOLD}Root Disk:${C_RESET} Total: ${disk_total} | Used: ${disk_used} | Available: ${disk_avail}"
    fi

    # Boot time / Uptime
    if command -v uptime &>/dev/null; then
        local uptime_info
        uptime_info="$(uptime -p 2>/dev/null || uptime | sed 's/.*up /up /' | cut -d',' -f1-2)"
        draw_box_line "${C_BOLD}Uptime:${C_RESET} ${uptime_info}"
    fi

    printf '\n'
}

# ─────────────────────────────────────────────────────────────────────────────
# LOG EXPORT FUNCTIONS (--save option)
# ─────────────────────────────────────────────────────────────────────────────

# Check available disk space, warn if below threshold
check_disk_space() {
    local target_dir="${1:-.}"
    local min_free_kb="${2:-102400}"  # Default: 100MB
    local check_path="$target_dir"

    # If target doesn't exist, check parent directory
    if [[ ! -e "$target_dir" ]]; then
        check_path="$(dirname "$target_dir")"
        # If parent doesn't exist either, check root
        [[ ! -d "$check_path" ]] && check_path="/"
    fi
    
    # Get parent directory if target is a file
    [[ -f "$target_dir" ]] && check_path="$(dirname "$target_dir")"

    # Get available space in KB
    local avail_kb
    avail_kb="$(df -k "$check_path" 2>/dev/null | awk 'NR==2 {print $4}')" || return 1

    if [[ -z "$avail_kb" || ! "$avail_kb" =~ ^[0-9]+$ ]]; then
        warn "Could not determine disk space for $check_path"
        return 1
    fi

    if [[ "$avail_kb" -lt "$min_free_kb" ]]; then
        local avail_mb=$((avail_kb / 1024))
        local min_mb=$((min_free_kb / 1024))
        warn "Low disk space: ${avail_mb}MB available, ${min_mb}MB recommended"
        return 1
    fi

    return 0
}

init_output_dir() {
    local timestamp
    timestamp="$(date +%Y%m%d_%H%M%S)"
    OUTPUT_DIR="./arch-diag-logs/${timestamp}"

    # Check disk space before creating directory
    if ! check_disk_space "$OUTPUT_DIR"; then
        warn "Insufficient disk space for export"
        return 1
    fi

    if ! mkdir -p "$OUTPUT_DIR" 2>/dev/null; then
        warn "Could not create output directory: $OUTPUT_DIR"
        return 1
    fi

    info "Logs will be saved to: $OUTPUT_DIR"
    return 0
}

export_kernel_logs() {
    local boot_flag="$1"
    
    # Guard: validate OUTPUT_DIR
    if [[ -z "$OUTPUT_DIR" || ! -d "$OUTPUT_DIR" ]]; then
        warn "export_kernel_logs: OUTPUT_DIR not set or invalid"
        return 1
    fi
    
    local output_file="${OUTPUT_DIR}/kernel_errors.txt"
    local journal_output

    journal_output="$(journalctl -k -p 3 "$boot_flag" --no-pager 2>/dev/null)" || true

    if [[ -z "$journal_output" ]]; then
        printf 'No kernel errors found for boot: %s\n' "$boot_flag" > "$output_file"
        return 0
    fi

    # Write raw log
    printf '%s\n' "$journal_output" > "$output_file"

    # Write clustered version
    local clustered_file="${OUTPUT_DIR}/kernel_errors_clustered.txt"
    printf '%s\n' "$journal_output" | \
        sed -E 's/^[A-Za-z]{3} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [^ ]+ //' | \
        sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4} [^ ]+ //' | \
        sort | uniq -c | sort -rn > "$clustered_file"

    info "Kernel logs exported: kernel_errors.txt, kernel_errors_clustered.txt"
}

export_user_services() {
    local boot_flag="$1"
    
    # Guard: validate OUTPUT_DIR
    if [[ -z "$OUTPUT_DIR" || ! -d "$OUTPUT_DIR" ]]; then
        warn "export_user_services: OUTPUT_DIR not set or invalid"
        return 1
    fi
    
    local output_file="${OUTPUT_DIR}/service_errors.txt"
    local journal_output

    journal_output="$(journalctl -u "*.service" -p 3 "$boot_flag" --no-pager 2>/dev/null)" || true

    if [[ -z "$journal_output" ]]; then
        printf 'No service errors found for boot: %s\n' "$boot_flag" > "$output_file"
        return 0
    fi

    printf '%s\n' "$journal_output" > "$output_file"
    info "Service logs exported: service_errors.txt"
}

export_coredumps() {
    # Guard: validate OUTPUT_DIR
    if [[ -z "$OUTPUT_DIR" || ! -d "$OUTPUT_DIR" ]]; then
        warn "export_coredumps: OUTPUT_DIR not set or invalid"
        return 1
    fi
    
    local output_file="${OUTPUT_DIR}/coredumps.txt"

    if ! command -v coredumpctl &>/dev/null; then
        printf 'coredumpctl not available\n' > "$output_file"
        return 0
    fi

    local coredumps
    coredumps="$(coredumpctl list --no-pager --no-legend 2>/dev/null)" || true

    if [[ -z "$coredumps" ]]; then
        printf 'No core dumps found\n' > "$output_file"
        return 0
    fi

    printf '%s\n' "$coredumps" > "$output_file"
    info "Core dumps exported: coredumps.txt"
}

export_pacman_logs() {
    # Guard: validate OUTPUT_DIR
    if [[ -z "$OUTPUT_DIR" || ! -d "$OUTPUT_DIR" ]]; then
        warn "export_pacman_logs: OUTPUT_DIR not set or invalid"
        return 1
    fi
    
    local output_file="${OUTPUT_DIR}/pacman_errors.txt"
    local pacman_log="/var/log/pacman.log"

    if [[ ! -f "$pacman_log" ]]; then
        printf 'Pacman log not found (may require root)\n' > "$output_file"
        return 0
    fi

    local issues
    issues="$(tail -100 "$pacman_log" 2>/dev/null | grep -iE '(error|warning)' | grep -v '^#')" || true

    if [[ -z "$issues" ]]; then
        printf 'No pacman errors or warnings found in last 100 lines\n' > "$output_file"
        return 0
    fi

    printf '%s\n' "$issues" > "$output_file"
    info "Pacman logs exported: pacman_errors.txt"
}

export_mounts() {
    # Guard: validate OUTPUT_DIR
    if [[ -z "$OUTPUT_DIR" || ! -d "$OUTPUT_DIR" ]]; then
        warn "export_mounts: OUTPUT_DIR not set or invalid"
        return 1
    fi
    
    local output_file="${OUTPUT_DIR}/mounts.txt"

    {
        printf '=============================================================\n'
        printf 'MOUNTED FILESYSTEMS\n'
        printf '=============================================================\n\n'

        if command -v findmnt &>/dev/null; then
            findmnt -rn -o SOURCE,TARGET,FSTYPE,SIZE 2>/dev/null || true
        else
            cat /proc/mounts 2>/dev/null || true
        fi

        printf '\n=============================================================\n'
        printf 'DISK USAGE\n'
        printf '=============================================================\n\n'

        df -h 2>/dev/null || true
    } > "$output_file"

    info "Mount info exported: mounts.txt"
}

export_usb_devices() {
    # Guard: validate OUTPUT_DIR
    if [[ -z "$OUTPUT_DIR" || ! -d "$OUTPUT_DIR" ]]; then
        warn "export_usb_devices: OUTPUT_DIR not set or invalid"
        return 1
    fi
    
    local output_file="${OUTPUT_DIR}/usb_devices.txt"

    {
        printf '=============================================================\n'
        printf 'USB DEVICES (lsusb)\n'
        printf '=============================================================\n\n'

        if command -v lsusb &>/dev/null; then
            lsusb -v 2>/dev/null | head -100 || true
        else
            printf 'lsusb not available\n'
        fi

        printf '\n=============================================================\n'
        printf 'USB STORAGE (lsblk)\n'
        printf '=============================================================\n\n'

        if command -v lsblk &>/dev/null; then
            lsblk -dnbo NAME,MODEL,SIZE,VENDOR,MOUNTPOINT 2>/dev/null | grep -E '^(sd|usb)' || true
        fi
    } > "$output_file"

    info "USB devices exported: usb_devices.txt"
}

export_vga_info() {
    # Guard: validate OUTPUT_DIR
    if [[ -z "$OUTPUT_DIR" || ! -d "$OUTPUT_DIR" ]]; then
        warn "export_vga_info: OUTPUT_DIR not set or invalid"
        return 1
    fi
    
    local output_file="${OUTPUT_DIR}/vga_info.txt"

    {
        printf '=============================================================\n'
        printf 'GPU / VGA INFORMATION\n'
        printf '=============================================================\n\n'
        printf 'Graphics Card: %s\n\n' "${GPU_INFO}"
        printf 'Display: %s\n\n' "${DISPLAY_INFO}"

        if command -v glxinfo &>/dev/null; then
            printf 'OpenGL Info:\n'
            glxinfo 2>/dev/null | grep -E 'OpenGL (vendor|renderer|version)' | head -5
        fi
    } > "$output_file"

    info "VGA info exported: vga_info.txt"
}

export_drivers() {
    # Guard: validate OUTPUT_DIR
    if [[ -z "$OUTPUT_DIR" || ! -d "$OUTPUT_DIR" ]]; then
        warn "export_drivers: OUTPUT_DIR not set or invalid"
        return 1
    fi
    
    local output_file="${OUTPUT_DIR}/drivers.txt"

    {
        printf '=============================================================\n'
        printf 'DRIVER STATUS\n'
        printf '=============================================================\n\n'

        printf 'Loaded Kernel Modules:\n'
        lsmod 2>/dev/null | head -50 || true

        printf '\n\nPCI Devices with Drivers:\n'
        lspci -k 2>/dev/null | head -50 || true
    } > "$output_file"

    info "Drivers exported: drivers.txt"
}

export_summary() {
    # Guard: validate OUTPUT_DIR
    if [[ -z "$OUTPUT_DIR" || ! -d "$OUTPUT_DIR" ]]; then
        warn "export_summary: OUTPUT_DIR not set or invalid"
        return 1
    fi
    
    local output_file="${OUTPUT_DIR}/summary.txt"
    local boot_flag="$1"

    # Wait a moment for all files to be written (0.3s to avoid race condition)
    sleep 0.3

    cat > "$output_file" <<EOF
=============================================================
ARLOGKN - Export Summary
=============================================================
Generated: $(date '+%Y-%m-%d %H:%M:%S')
System: ${DISTRO_NAME} (${DISTRO_TYPE})
Kernel: ${KERNEL_VER}
CPU Governor: ${CPU_GOVERNOR}
Boot Offset: ${BOOT_OFFSET}
=============================================================

Files exported:
EOF

    # List all txt files except summary.txt itself
    local f bname fname lines
    shopt -s nullglob
    for f in "$OUTPUT_DIR"/*.txt; do
        bname="$(basename "$f")"
        if [[ "$bname" != "summary.txt" ]]; then
            fname="$bname"
            lines="$(wc -l < "$f")"
            printf '  - %s (%s lines)\n' "$fname" "$lines" >> "$output_file"
        fi
    done
    shopt -u nullglob

    printf '\n=============================================================\n' >> "$output_file"
    info "Summary exported: summary.txt"
}

# ─────────────────────────────────────────────────────────────────────────────
# CONSOLIDATED EXPORT (ALL LOGS IN ONE FILE)
# ─────────────────────────────────────────────────────────────────────────────

export_all_logs() {
    local boot_flag="$1"
    
    # Guard: validate OUTPUT_DIR
    if [[ -z "$OUTPUT_DIR" || ! -d "$OUTPUT_DIR" ]]; then
        warn "export_all_logs: OUTPUT_DIR not set or invalid"
        return 1
    fi
    
    local output_file="${OUTPUT_DIR}/arch-log-inspector-all.txt"
    local temp_file
    temp_file="$(mktemp)"

    # Cleanup trap: ensure temp file is removed on exit/error
    trap 'rm -f "$temp_file" 2>/dev/null || true' RETURN EXIT

    {
        printf '=============================================================\n'
        printf 'ARLOGKN - FULL LOG EXPORT\n'
        printf '=============================================================\n'
        printf 'Generated: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf 'System: %s (%s)\n' "${DISTRO_NAME}" "${DISTRO_TYPE}"
        printf 'Kernel: %s\n' "${KERNEL_VER}"
        printf 'CPU Governor: %s\n' "${CPU_GOVERNOR}"
        printf 'Boot Offset: %s\n' "${BOOT_OFFSET}"
        printf '=============================================================\n\n'

        # ─────────────────────────────────────────────────────────────────────
        # KERNEL LOGS
        # ─────────────────────────────────────────────────────────────────────
        printf '=============================================================\n'
        printf '[1] KERNEL LOGS (Priority ≤3 - Errors)\n'
        printf '=============================================================\n'
        local kernel_output
        kernel_output="$(journalctl -k -p 3 "$boot_flag" --no-pager 2>/dev/null)" || true
        if [[ -n "$kernel_output" ]]; then
            printf '%s\n' "$kernel_output"
        else
            printf 'No kernel errors found.\n'
        fi
        printf '\n\n'

        # ─────────────────────────────────────────────────────────────────────
        # USER SERVICES
        # ─────────────────────────────────────────────────────────────────────
        printf '=============================================================\n'
        printf '[2] USER SERVICES (Failed Services)\n'
        printf '=============================================================\n'
        local service_output
        service_output="$(journalctl -u "*.service" -p 3 "$boot_flag" --no-pager 2>/dev/null)" || true
        if [[ -n "$service_output" ]]; then
            printf '%s\n' "$service_output"
        else
            printf 'No service errors found.\n'
        fi
        printf '\n\n'

        # ─────────────────────────────────────────────────────────────────────
        # CORE DUMPS
        # ─────────────────────────────────────────────────────────────────────
        printf '=============================================================\n'
        printf '[3] CORE DUMPS\n'
        printf '=============================================================\n'
        if command -v coredumpctl &>/dev/null; then
            local coredumps
            coredumps="$(coredumpctl list --no-pager --no-legend 2>/dev/null)" || true
            if [[ -n "$coredumps" ]]; then
                printf '%s\n' "$coredumps"
            else
                printf 'No core dumps found.\n'
            fi
        else
            printf 'coredumpctl not available.\n'
        fi
        printf '\n\n'

        # ─────────────────────────────────────────────────────────────────────
        # PACMAN LOGS
        # ─────────────────────────────────────────────────────────────────────
        printf '=============================================================\n'
        printf '[4] PACMAN LOGS (Errors & Warnings)\n'
        printf '=============================================================\n'
        local pacman_log="/var/log/pacman.log"
        if [[ -f "$pacman_log" ]]; then
            local pacman_issues
            pacman_issues="$(tail -100 "$pacman_log" 2>/dev/null | grep -iE '(error|warning)' | grep -v '^#')" || true
            if [[ -n "$pacman_issues" ]]; then
                printf '%s\n' "$pacman_issues"
            else
                printf 'No pacman errors or warnings found in last 100 lines.\n'
            fi
        else
            printf 'Pacman log not found (may require root).\n'
        fi
        printf '\n\n'

        # ─────────────────────────────────────────────────────────────────────
        # MOUNTED FILESYSTEMS
        # ─────────────────────────────────────────────────────────────────────
        printf '=============================================================\n'
        printf '[5] MOUNTED FILESYSTEMS\n'
        printf '=============================================================\n'
        if command -v findmnt &>/dev/null; then
            findmnt -rn -o SOURCE,TARGET,FSTYPE,SIZE 2>/dev/null || true
        else
            cat /proc/mounts 2>/dev/null || true
        fi
        printf '\n\n'

        # ─────────────────────────────────────────────────────────────────────
        # DISK USAGE
        # ─────────────────────────────────────────────────────────────────────
        printf '=============================================================\n'
        printf '[6] DISK USAGE\n'
        printf '=============================================================\n'
        df -h 2>/dev/null || true
        printf '\n\n'

        # ─────────────────────────────────────────────────────────────────────
        # USB DEVICES
        # ─────────────────────────────────────────────────────────────────────
        printf '=============================================================\n'
        printf '[7] USB DEVICES\n'
        printf '=============================================================\n'
        if command -v lsusb &>/dev/null; then
            lsusb -v 2>/dev/null | head -100 || true
        else
            printf 'lsusb not available.\n'
        fi
        printf '\n\n'

        # ─────────────────────────────────────────────────────────────────────
        # GPU / VGA INFO
        # ─────────────────────────────────────────────────────────────────────
        printf '=============================================================\n'
        printf '[8] GPU / VGA INFO\n'
        printf '=============================================================\n'
        printf 'Graphics Card: %s\n\n' "${GPU_INFO}"
        printf 'Display: %s\n\n' "${DISPLAY_INFO}"
        if command -v glxinfo &>/dev/null; then
            printf 'OpenGL Info:\n'
            glxinfo 2>/dev/null | grep -E 'OpenGL (vendor|renderer|version)' | head -5
        fi
        printf '\n\n'

        # ─────────────────────────────────────────────────────────────────────
        # DRIVER STATUS
        # ─────────────────────────────────────────────────────────────────────
        printf '=============================================================\n'
        printf '[9] DRIVER STATUS\n'
        printf '=============================================================\n'
        printf 'Loaded Kernel Modules:\n'
        lsmod 2>/dev/null | head -50 || true
        printf '\n\nPCI Devices with Drivers:\n'
        lspci -k 2>/dev/null | head -50 || true
        printf '\n\n'

        # ─────────────────────────────────────────────────────────────────────
        # SYSTEM INFO
        # ─────────────────────────────────────────────────────────────────────
        printf '=============================================================\n'
        printf '[10] SYSTEM INFO\n'
        printf '=============================================================\n'
        printf 'Internet: %s\n' "$INTERNET_STATUS"
        printf 'CPU: %s\n' "$(grep 'model name' /proc/cpuinfo 2>/dev/null | head -1 | cut -d':' -f2 | sed 's/^ *//' || echo 'Unknown')"
        printf 'CPU Cores: %s\n' "$(nproc 2>/dev/null || echo '?')"
        printf 'Memory:\n'
        free -h 2>/dev/null || true
        printf '\nUptime: %s\n' "$(uptime -p 2>/dev/null || uptime | sed 's/.*up /up /' | cut -d',' -f1-2)"
        printf '\n\n'

        printf '=============================================================\n'
        printf 'END OF LOG EXPORT\n'
        printf '=============================================================\n'

    } > "$temp_file"

    # Move temp file to final location
    if ! mv "$temp_file" "$output_file"; then
        warn "Failed to move temp file to $output_file"
        return 1
    fi

    # Reset trap after successful move (temp file no longer exists)
    trap - RETURN EXIT

    info "All logs exported to: ${output_file}"
}

# ─────────────────────────────────────────────────────────────────────────────
# CLI ARGUMENT PARSER (MANUAL - NO GETOPT)
# ─────────────────────────────────────────────────────────────────────────────

parse_args() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --all)
                SCAN_ALL=1
                SCAN_KERNEL=0
                SCAN_USER=0
                SCAN_MOUNT=0
                SCAN_USB=0
                ;;
            --kernel)
                SCAN_ALL=0
                SCAN_KERNEL=1
                SCAN_USER=0
                SCAN_MOUNT=0
                SCAN_USB=0
                ;;
            --user)
                SCAN_ALL=0
                SCAN_KERNEL=0
                SCAN_USER=1
                SCAN_MOUNT=0
                SCAN_USB=0
                ;;
            --mount)
                SCAN_ALL=0
                SCAN_MOUNT=1
                ;;
            --usb)
                SCAN_ALL=0
                SCAN_USB=1
                ;;
            --driver)
                SCAN_ALL=0
                SCAN_DRIVER=1
                ;;
            --vga)
                SCAN_ALL=0
                SCAN_VGA=1
                ;;
            --system)
                # Full system scan (mount + usb + driver + vga + system info)
                SCAN_ALL=0
                SCAN_SYSTEM=1
                ;;
            --wiki|--wiki=*)
                SCAN_ALL=0
                SCAN_WIKI=1
                # Handle optional group argument: --wiki or --wiki=group
                if [[ "$arg" == --wiki=* ]]; then
                    WIKI_GROUP="${arg#--wiki=}"
                fi
                ;;
            --wiki-group=*)
                SCAN_ALL=0
                SCAN_WIKI=1
                WIKI_GROUP="${arg#--wiki-group=}"
                ;;
            --boot=*)
                BOOT_OFFSET="${arg#--boot=}"
                # Validate numeric
                if ! [[ "$BOOT_OFFSET" =~ ^-?[0-9]+$ ]]; then
                    die "Invalid boot offset: $BOOT_OFFSET (must be integer)"
                fi
                ;;
            --save)
                SAVE_LOGS=1
                ;;
            --save-all)
                SAVE_ALL=1
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            --version|-v)
                printf '%s version %s\n' "$SCRIPT_NAME" "$VERSION"
                exit 0
                ;;
            *)
                die "Unknown argument: $arg (use --help for usage)"
                ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# WIKI GROUP DEFINITIONS (for lookup and suggestions)
# ─────────────────────────────────────────────────────────────────────────────

# Group keywords for matching (lowercase, space-separated)
declare -ga WIKI_GROUP_NAMES=(
    "pacman package management"
    "aur helpers yay paru"
    "system information"
    "process service management systemctl"
    "hardware detection lspci lsusb"
    "disk filesystem mount"
    "network diagnostics"
    "user permissions"
    "logs debugging journal"
    "arch utilities"
    "performance monitoring"
    "backup recovery"
    "troubleshooting diagnostics"
    "boot startup repair"
    "memory swap"
    "graphics display gpu"
    "sound audio pulseaudio"
    "systemd journal"
    "file permission debug"
    "emergency recovery"
)

# Find group index by keyword match (returns 0-based index or -1)
# Note: i++ is intentionally outside the qword loop - we check ALL keywords
# in the query against the current group before moving to the next group.
# This ensures "sound graphics" matches group 16 (graphics) even if group 15
# (memory swap) doesn't match "sound".
find_wiki_group() {
    local query="$1"
    local i=0

    # Normalize query: lowercase, trim whitespace
    query="$(echo "$query" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -s ' ')"

    for group in "${WIKI_GROUP_NAMES[@]}"; do
        # Check if any keyword in query matches any keyword in group
        local qword
        for qword in $query; do
            if [[ "$group" == *"$qword"* ]]; then
                echo "$i"
                return 0
            fi
        done
        ((i++))
    done

    echo "-1"
    return 1
}

# Get similar group suggestions (for typos)
suggest_wiki_groups() {
    local query="$1"
    local suggestions=()
    
    # Normalize query
    query="$(echo "$query" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    local query_len=${#query}
    
    for group in "${WIKI_GROUP_NAMES[@]}"; do
        # Check all words in the group
        local word
        for word in $group; do
            local word_len=${#word}
            
            # Check if query is similar to word (within 2 chars difference)
            local len_diff=$((query_len - word_len))
            [[ $len_diff -lt 0 ]] && len_diff=$((-len_diff))
            
            # Substring match or close length match
            if [[ "$word" == *"$query"* ]] || [[ "$query" == *"$word"* ]]; then
                suggestions+=("$group")
                break
            fi
            
            # Check for common typos (missing one char)
            if [[ $len_diff -eq 1 ]] || [[ $len_diff -eq -1 ]]; then
                # Check if query without one char matches word
                local shorter longer
                if [[ $query_len -lt $word_len ]]; then
                    shorter="$query"
                    longer="$word"
                else
                    shorter="$word"
                    longer="$query"
                fi
                
                # Try removing each char from longer and compare
                local i
                for ((i=0; i<${#longer}; i++)); do
                    local modified="${longer:0:i}${longer:i+1}"
                    if [[ "$modified" == "$shorter" ]]; then
                        suggestions+=("$group")
                        break 2
                    fi
                done
            fi
        done
    done
    
    # Return suggestions
    if [[ ${#suggestions[@]} -gt 0 ]]; then
        printf '%s\n' "${suggestions[@]}" | head -3
    fi
}

# Display a single wiki group by index (0-based)
show_wiki_group() {
    local group_idx="$1"
    
    # Detect terminal width
    local term_width
    term_width="$(tput cols 2>/dev/null)" || term_width=80
    [[ -z "$term_width" || "$term_width" -lt 70 ]] && term_width=80
    
    local col1_width=35
    local col2_width=30
    if [[ "$term_width" -lt 80 ]]; then
        col1_width=30
        col2_width=25
    fi
    
    printf '\n'
    draw_header "ARCH LINUX COMMAND WIKI"
    printf '\n'
    
    case "$group_idx" in
        0)  # Package Management
            draw_section_header "1. PACKAGE MANAGEMENT (PACMAN)"
            draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
            tbl_row "pacman -Syu" "Full system upgrade"
            tbl_row "pacman -S <pkg>" "Install package(s)"
            tbl_row "pacman -R <pkg>" "Remove package(s)"
            tbl_row "pacman -Rns <pkg>" "Remove pkg + deps + config"
            tbl_row "pacman -Q" "List installed packages"
            tbl_row "pacman -Qe" "List explicitly installed"
            tbl_row "pacman -Qdt" "List orphaned packages"
            tbl_row "pacman -F <file>" "Find which pkg owns file"
            tbl_row "pacman -Dk" "Check pkg database integrity"
            tbl_row "pacman -Sc" "Clean unused pkgs from cache"
            tbl_row "pacman -Scc" "Clean all cache (dangerous)"
            tbl_row "pacman -Sl" "List all available packages"
            tbl_row "pacman -Si <pkg>" "Show package info"
            tbl_row "pacman -Ql <pkg>" "List files owned by pkg"
            tbl_row "pacman -Qo <file>" "Find pkg that owns file"
            tbl_row "pacman -U <file.pkg.tar>" "Install local package file"
            draw_table_end
            ;;
        1)  # AUR Helpers
            draw_section_header "2. AUR HELPERS (YAY/PARU)"
            draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
            tbl_row "yay -S <pkg>" "Install from AUR/official"
            tbl_row "yay -Syu" "Update all (AUR + official)"
            tbl_row "yay -Qm" "List AUR packages"
            tbl_row "yay -Rns <pkg>" "Remove AUR package"
            tbl_row "yay -Ps" "Show stats"
            tbl_row "yay -G <pkg>" "Download PKGBUILD only"
            tbl_row "yay -w <pkg>" "Download sources only"
            tbl_row "paru -S <pkg>" "Paru equivalent (same syntax)"
            draw_table_end
            ;;
        2)  # System Information
            draw_section_header "3. SYSTEM INFORMATION"
            draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
            tbl_row "uname -r" "Show kernel version"
            tbl_row "uname -a" "Show all system info"
            tbl_row "hostnamectl" "Show hostname & boot time"
            tbl_row "cat /etc/os-release" "Show distribution info"
            tbl_row "neofetch" "System info with ASCII art"
            tbl_row "fastfetch" "Faster neofetch alternative"
            tbl_row "lscpu" "CPU architecture info"
            tbl_row "nproc" "Number of CPU cores"
            tbl_row "free -h" "Memory usage (human readable)"
            tbl_row "df -h" "Disk space (human readable)"
            tbl_row "lsblk" "List block devices"
            tbl_row "blkid" "Show block device UUIDs"
            tbl_row "lsmod" "List loaded kernel modules"
            tbl_row "modinfo <mod>" "Show module information"
            tbl_row "inxi -Fza" "Full system info (detailed)"
            draw_table_end
            ;;
        3)  # Process & Service Management
            draw_section_header "4. PROCESS & SERVICE MANAGEMENT"
            draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
            tbl_row "systemctl status" "Show systemd overview"
            tbl_row "systemctl list-units" "List active units"
            tbl_row "systemctl list-timers" "List systemd timers"
            tbl_row "systemctl start <svc>" "Start a service"
            tbl_row "systemctl stop <svc>" "Stop a service"
            tbl_row "systemctl restart <svc>" "Restart a service"
            tbl_row "systemctl enable <svc>" "Enable at boot"
            tbl_row "systemctl disable <svc>" "Disable at boot"
            tbl_row "systemctl daemon-reload" "Reload systemd config"
            tbl_row "journalctl -b" "Logs from current boot"
            tbl_row "journalctl -b -1" "Logs from previous boot"
            tbl_row "journalctl -f" "Follow logs (tail -f)"
            tbl_row "journalctl -u <svc>" "Logs for specific service"
            tbl_row "journalctl -p 3" "Show priority ≤ ERR"
            tbl_row "ps aux" "Show all processes"
            tbl_row "top" "Interactive process viewer"
            tbl_row "htop" "Enhanced top (if installed)"
            tbl_row "kill <PID>" "Terminate process"
            tbl_row "killall <name>" "Kill by process name"
            tbl_row "pkill <pattern>" "Kill by pattern"
            draw_table_end
            ;;
        4)  # Hardware Detection
            draw_section_header "5. HARDWARE DETECTION"
            draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
            tbl_row "lspci" "List PCI devices"
            tbl_row "lspci -k" "PCI + kernel drivers"
            tbl_row "lspci -nn" "PCI with vendor IDs"
            tbl_row "lspci -v" "PCI verbose output"
            tbl_row "lsusb" "List USB devices"
            tbl_row "lsusb -t" "USB tree view"
            tbl_row "lsusb -v" "USB verbose output"
            tbl_row "lshw" "Hardware list (needs root)"
            tbl_row "lshw -short" "Short hardware summary"
            tbl_row "hwinfo" "Hardware info tool"
            tbl_row "dmidecode" "DMI/SMBIOS table dump"
            tbl_row "upower -i /dev" "Power/battery info"
            tbl_row "iwctl" "Wireless CLI tool"
            tbl_row "iwconfig" "Wireless config (legacy)"
            tbl_row "ip addr" "Show IP addresses"
            tbl_row "ip route" "Show routing table"
            draw_table_end
            ;;
        5)  # Disk & Filesystem
            draw_section_header "6. DISK & FILESYSTEM"
            draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
            tbl_row "fdisk -l" "List partitions"
            tbl_row "parted -l" "Partition table info"
            tbl_row "mkfs.<type> <dev>" "Create filesystem"
            tbl_row "mount <dev> <mnt>" "Mount device"
            tbl_row "umount <dev|mnt>" "Unmount device"
            tbl_row "findmnt" "Tree of mounted filesystems"
            tbl_row "cat /proc/mounts" "Active mounts list"
            tbl_row "du -sh <dir>" "Directory size"
            tbl_row "du -h --max-depth=1" "Subdir sizes"
            tbl_row "ncdu" "NCurses disk usage"
            tbl_row "btrfs filesystem usage" "Btrfs space info"
            tbl_row "fsck <dev>" "Filesystem check"
            tbl_row "smartctl -a <dev>" "SMART disk health"
            tbl_row "hdparm -Tt <dev>" "Disk speed test"
            draw_table_end
            ;;
        6)  # Network Diagnostics
            draw_section_header "7. NETWORK DIAGNOSTICS"
            draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
            tbl_row "ping <host>" "Test connectivity"
            tbl_row "ping -6 <host>" "IPv6 ping"
            tbl_row "traceroute <host>" "Trace network path"
            tbl_row "tracepath <host>" "Path MTU discovery"
            tbl_row "mtr <host>" "Ping + traceroute combo"
            tbl_row "dig <domain>" "DNS lookup"
            tbl_row "nslookup <domain>" "DNS query (legacy)"
            tbl_row "host <domain>" "Simple DNS lookup"
            tbl_row "curl <url>" "Transfer data from URL"
            tbl_row "wget <url>" "Download files"
            tbl_row "ss -tulpn" "Show listening ports"
            tbl_row "netstat -tulpn" "Netstat (legacy)"
            tbl_row "nmap <host>" "Network scanner"
            tbl_row "ip link" "Show network interfaces"
            tbl_row "ip neigh" "Show ARP table"
            tbl_row "resolvectl status" "DNS resolver status"
            draw_table_end
            ;;
        7)  # User & Permissions
            draw_section_header "8. USER & PERMISSIONS"
            draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
            tbl_row "id" "Show current user ID"
            tbl_row "whoami" "Show current username"
            tbl_row "users" "Logged in users"
            tbl_row "w" "Who + what they're doing"
            tbl_row "last" "Login history"
            tbl_row "lastb" "Failed login attempts"
            tbl_row "sudo -i" "Become root (interactive)"
            tbl_row "su - <user>" "Switch user"
            tbl_row "chmod <mode> <file>" "Change permissions"
            tbl_row "chown <user> <file>" "Change ownership"
            tbl_row "getfacl <file>" "Show ACL permissions"
            tbl_row "setfacl -m <rule>" "Set ACL permissions"
            tbl_row "passwd <user>" "Change password"
            tbl_row "groups <user>" "Show user groups"
            draw_table_end
            ;;
        8)  # Logs & Debugging
            draw_section_header "9. LOGS & DEBUGGING"
            draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
            tbl_row "journalctl" "View systemd journal"
            tbl_row "journalctl -xe" "Journal + explanations"
            tbl_row "journalctl --disk-usage" "Journal disk usage"
            tbl_row "journalctl --vacuum" "Vacuum old journals"
            tbl_row "dmesg" "Kernel ring buffer"
            tbl_row "dmesg -w" "Follow kernel messages"
            tbl_row "coredumpctl list" "List core dumps"
            tbl_row "coredumpctl info" "Core dump details"
            tbl_row "strace <cmd>" "Trace syscalls"
            tbl_row "ltrace <cmd>" "Trace library calls"
            tbl_row "gdb <bin>" "GNU debugger"
            tbl_row "valgrind <cmd>" "Memory debugger"
            draw_table_end
            ;;
        9)  # Arch Utilities
            draw_section_header "10. ARCH-SPECIFIC UTILITIES"
            draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
            tbl_row "archlinux-keyring-wkd" "Update keyring"
            tbl_row "pacman-key --init" "Init pacman keyring"
            tbl_row "pacman-key --populate" "Populate keyring"
            tbl_row "reflector" "Mirrorlist generator"
            tbl_row "rankmirrors" "Rank mirrors by speed"
            tbl_row "makepkg -si" "Build PKGBUILD + install"
            tbl_row "makepkg --clean" "Clean build dir"
            tbl_row "pkgfile <cmd>" "Find pkg providing cmd"
            tbl_row "pactree <pkg>" "Show dependency tree"
            tbl_row "vercmp <v1> <v2>" "Compare versions"
            tbl_row "namcap <pkg>" "Package analyzer"
            tbl_row "debuginfod-find" "Find debug symbols (elfutils)"
            draw_table_end
            ;;
        10) # Performance & Monitoring
            draw_section_header "11. PERFORMANCE & MONITORING"
            draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
            tbl_row "vmstat" "Virtual memory stats"
            tbl_row "iostat" "I/O statistics"
            tbl_row "mpstat" "CPU stats per core"
            tbl_row "sar" "System activity report"
            tbl_row "pidstat" "Per-process stats"
            tbl_row "iotop" "Disk I/O by process (iotop)"
            tbl_row "nethogs" "Bandwidth by process (nethogs)"
            tbl_row "iftop" "Network bandwidth (iftop)"
            tbl_row "perf top" "CPU profiling"
            tbl_row "powertop" "Power consumption (powertop)"
            tbl_row "cpupower frequency-info" "CPU freq info"
            tbl_row "cpupower frequency-set" "Set CPU governor"
            draw_table_end
            ;;
        11) # Backup & Recovery
            draw_section_header "12. BACKUP & RECOVERY"
            draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
            tbl_row "rsync -av <src> <dst>" "Sync files/dirs"
            tbl_row "tar -czf <a.tar.gz>" "Create archive"
            tbl_row "tar -xzf <a.tar.gz>" "Extract archive"
            tbl_row "dd if=<in> of=<out>" "Block copy (careful!)"
            tbl_row "timeshift" "System snapshot tool (timeshift)"
            tbl_row "snapper list" "Btrfs snapshot list (snapper)"
            tbl_row "fsarchiver" "Filesystem archiver (fsarchiver)"
            tbl_row "clonezilla" "Disk imaging tool (Live OS)"
            draw_table_end
            ;;
        12) # Troubleshooting & Diagnostics
            draw_section_header "13. TROUBLESHOOTING & DIAGNOSTICS"
            draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
            tbl_row "dmesg -T" "Kernel messages with timestamps"
            tbl_row "dmesg -l err" "Show only error messages"
            tbl_row "dmesg -l warn" "Show only warnings"
            tbl_row "journalctl -p err -b" "Errors from current boot"
            tbl_row "journalctl -p warning -b" "Warnings from current boot"
            tbl_row "systemctl --failed" "List failed services"
            tbl_row "systemctl is-failed <svc>" "Check if service failed"
            tbl_row "coredumpctl list" "List application crashes"
            tbl_row "coredumpctl gdb <exe>" "Debug crash with gdb"
            tbl_row "strace -p <PID>" "Trace running process"
            tbl_row "lsof -p <PID>" "List open files by PID"
            tbl_row "lsof -i :<port>" "Find process on port"
            tbl_row "fuser -v <file>" "Find processes using file"
            tbl_row "inxi -Fxxxz" "Full hardware info (inxi)"
            tbl_row "hwinfo --short" "Hardware summary (hwinfo)"
            draw_table_end
            ;;
        13) # Boot & Startup Repair
            draw_section_header "14. BOOT & STARTUP REPAIR"
            draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
            tbl_row "bootctl status" "Check boot loader status"
            tbl_row "efibootmgr -v" "List EFI boot entries"
            tbl_row "grub-mkconfig -o /boot/grub..." "Regenerate GRUB config"
            tbl_row "mkinitcpio -P" "Regenerate initramfs"
            tbl_row "mkinitcpio -p linux" "Rebuild for specific kernel"
            tbl_row "pacman -S linux" "Reinstall kernel"
            tbl_row "arch-chroot /mnt" "Chroot into installed system"
            tbl_row "fstab-gen" "Generate fstab file"
            tbl_row "blkid" "Show block device UUIDs"
            tbl_row "lsblk -f" "List devices with filesystems"
            draw_table_end
            ;;
        14) # Memory & Swap
            draw_section_header "15. MEMORY & SWAP"
            draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
            tbl_row "free -h" "Memory and swap usage"
            tbl_row "vmstat -s" "Memory statistics"
            tbl_row "swapon --show" "Show swap devices"
            tbl_row "swapon -a" "Enable all swap"
            tbl_row "swapoff -a" "Disable all swap"
            tbl_row "mkswap /dev/<part>" "Create swap space"
            tbl_row "zramctl" "ZRAM compression status"
            tbl_row "smem -tk" "Memory usage by process (smem)"
            tbl_row "pmap -x <PID>" "Process memory mapping"
            draw_table_end
            ;;
        15) # Graphics & Display
            draw_section_header "16. GRAPHICS & DISPLAY"
            draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
            tbl_row "glxinfo -B" "OpenGL renderer info (mesa-utils)"
            tbl_row "glxgears" "OpenGL benchmark (mesa-utils)"
            tbl_row "vulkaninfo" "Vulkan GPU info (vulkan-tools)"
            tbl_row "xrandr" "Display configuration"
            tbl_row "xrandr --query" "List connected displays"
            tbl_row "nvidia-smi" "NVIDIA GPU status (nvidia-utils)"
            tbl_row "radeontop" "AMD GPU utilization (AUR)"
            tbl_row "intel_gpu_top" "Intel GPU util (intel-gpu-tools)"
            tbl_row "vainfo" "Video acceleration info (libva-utils)"
            tbl_row "libinput list-devices" "Input devices info"
            draw_table_end
            ;;
        16) # Sound & Audio
            draw_section_header "17. SOUND & AUDIO"
            draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
            tbl_row "pactl list short sinks" "List audio outputs"
            tbl_row "pactl list short sources" "List audio inputs"
            tbl_row "pactl info" "PulseAudio server info"
            tbl_row "pavucontrol" "PulseAudio volume control"
            tbl_row "alsamixer" "ALSA mixer interface"
            tbl_row "aplay -l" "List ALSA playback devices"
            tbl_row "arecord -l" "List ALSA capture devices"
            tbl_row "speaker-test -c 2" "Test stereo speakers"
            tbl_row "wireplumber" "PipeWire session manager"
            draw_table_end
            ;;
        17) # Systemd Journal Control
            draw_section_header "18. SYSTEMD JOURNAL CONTROL"
            draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
            tbl_row "journalctl --list-boots" "List boot entries"
            tbl_row "journalctl -b -1" "Previous boot logs"
            tbl_row "journalctl -b -2" "Two boots ago logs"
            tbl_row "journalctl --since today" "Logs from today"
            tbl_row "journalctl --since 1h ago" "Last hour logs"
            tbl_row "journalctl -u <svc>" "Service-specific logs"
            tbl_row "journalctl -t <tag>" "Logs by identifier"
            tbl_row "journalctl -k" "Kernel-only logs"
            tbl_row "journalctl -f" "Follow logs (live)"
            tbl_row "journalctl --vacuum-time=7d" "Keep 7 days of logs"
            tbl_row "journalctl --disk-usage" "Journal disk usage"
            tbl_row "journalctl --rotate" "Force log rotation"
            draw_table_end
            ;;
        18) # File & Permission Debug
            draw_section_header "19. FILE & PERMISSION DEBUG"
            draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
            tbl_row "stat <file>" "File metadata"
            tbl_row "ls -la <dir>" "List files with permissions"
            tbl_row "getfacl <file>" "Show ACL permissions"
            tbl_row "namei -l /path" "Trace path permissions"
            tbl_row "findmnt -D" "Find mount by device"
            tbl_row "lsof +D <dir>" "Open files in directory"
            tbl_row "fuser -vm <mount>" "Processes using mount"
            tbl_row "du -sh /*" "Top-level disk usage"
            tbl_row "ncdu" "Interactive disk usage (ncdu)"
            draw_table_end
            ;;
        19) # Emergency & Recovery
            draw_section_header "20. EMERGENCY & RECOVERY"
            draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
            tbl_row "systemctl emergency" "Enter emergency mode"
            tbl_row "systemctl rescue" "Enter rescue mode"
            tbl_row "mount -o remount,rw /" "Remount root as read-write"
            tbl_row "fsck -y /dev/<part>" "Auto-fix filesystem"
            tbl_row "test -x /file" "Test if file executable"
            tbl_row "pacman-key --refresh-keys" "Refresh package keys"
            tbl_row "pacman -Syyu" "Force full system upgrade"
            tbl_row "downgrade <pkg>" "Downgrade package (AUR)"
            draw_table_end
            ;;
    esac
    
    printf '\n'
    draw_box_line "${C_GREEN}✓ For more: https://wiki.archlinux.org${C_RESET}"
    draw_box_line "${C_CYAN}Tip: Use 'man <command>' for detailed documentation${C_RESET}"
    draw_box_line "${C_YELLOW}Note: Some commands require root privileges${C_RESET}"
    draw_footer
    printf '\n'
}

show_wiki() {
    # Check if user requested a specific group
    if [[ -n "$WIKI_GROUP" ]]; then
        # Normalize input: trim whitespace, lowercase for matching
        local normalized_group
        normalized_group="$(echo "$WIKI_GROUP" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

        # Find matching group (use || true to prevent exit on no match due to set -e)
        local group_idx
        group_idx="$(find_wiki_group "$normalized_group" || true)"

        if [[ "$group_idx" -ge 0 ]]; then
            # Found match - display single group
            show_wiki_group "$group_idx"
            return 0
        else
            # No match - show suggestions
            printf '\n'
            draw_header "ARCH LINUX COMMAND WIKI"
            printf '\n'
            draw_box_line "${C_RED}✗ Group not found: '${C_BOLD}$normalized_group${C_RED}'${C_RESET}"
            printf '\n'

            local suggestions
            suggestions="$(suggest_wiki_groups "$normalized_group" || true)"
            
            if [[ -n "$suggestions" ]]; then
                draw_box_line "${C_YELLOW}Did you mean one of these?${C_RESET}"
                printf '\n'
                draw_box_line "  ${C_CYAN}--wiki pacman${C_RESET}        - Package management"
                draw_box_line "  ${C_CYAN}--wiki sound${C_RESET}         - Sound & audio"
                draw_box_line "  ${C_CYAN}--wiki graphics${C_RESET}      - Graphics & display"
                draw_box_line "  ${C_CYAN}--wiki network${C_RESET}       - Network diagnostics"
                draw_box_line "  ${C_CYAN}--wiki boot${C_RESET}          - Boot & startup repair"
                draw_box_line "  ${C_CYAN}--wiki memory${C_RESET}        - Memory & swap"
                draw_box_line "  ${C_CYAN}--wiki systemd${C_RESET}       - Systemd journal"
                draw_box_line "  ${C_CYAN}--wiki troubleshooting${C_RESET} - Troubleshooting"
                printf '\n'
                draw_box_line "${C_CYAN}Tip: Use keywords like 'pacman', 'sound', 'gpu', 'boot', etc.${C_RESET}"
            else
                draw_box_line "${C_CYAN}Available groups: 1-20 or keywords${C_RESET}"
                draw_box_line "${C_CYAN}Examples:${C_RESET}"
                printf '\n'
                draw_box_line "  ${C_BOLD}--wiki pacman${C_RESET}           - Package management"
                draw_box_line "  ${C_BOLD}--wiki aur${C_RESET}              - AUR helpers"
                draw_box_line "  ${C_BOLD}--wiki system${C_RESET}           - System information"
                draw_box_line "  ${C_BOLD}--wiki process${C_RESET}          - Process & services"
                draw_box_line "  ${C_BOLD}--wiki hardware${C_RESET}         - Hardware detection"
                draw_box_line "  ${C_BOLD}--wiki disk${C_RESET}             - Disk & filesystem"
                draw_box_line "  ${C_BOLD}--wiki network${C_RESET}          - Network diagnostics"
                draw_box_line "  ${C_BOLD}--wiki sound${C_RESET}            - Sound & audio"
                draw_box_line "  ${C_BOLD}--wiki graphics${C_RESET}         - Graphics & display"
                draw_box_line "  ${C_BOLD}--wiki boot${C_RESET}             - Boot & startup"
                draw_box_line "  ${C_BOLD}--wiki memory${C_RESET}           - Memory & swap"
                draw_box_line "  ${C_BOLD}--wiki systemd${C_RESET}          - Systemd journal"
                draw_box_line "  ${C_BOLD}--wiki troubleshooting${C_RESET}  - Troubleshooting"
                draw_box_line "  ${C_BOLD}--wiki emergency${C_RESET}        - Emergency & recovery"
            fi
            
            draw_footer
            printf '\n'
            return 0
        fi
    fi
    
    # No group specified - show all groups (existing behavior)
    # Detect terminal width dynamically
    local term_width
    term_width="$(tput cols 2>/dev/null)" || term_width=80
    [[ -z "$term_width" || "$term_width" -lt 70 ]] && term_width=80

    # Adjust table column widths based on terminal width
    local col1_width=35
    local col2_width=30

    # If terminal is narrow, reduce column widths
    if [[ "$term_width" -lt 80 ]]; then
        col1_width=30
        col2_width=25
    fi

    printf '\n'
    draw_header "ARCH LINUX COMMAND WIKI"
    printf '\n'

    # ─────────────────────────────────────────────────────────────────────────
    # GROUP 1: PACKAGE MANAGEMENT (PACMAN)
    # ─────────────────────────────────────────────────────────────────────────
    draw_section_header "1. PACKAGE MANAGEMENT (PACMAN)"

    draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
    tbl_row "pacman -Syu" "Full system upgrade"
    tbl_row "pacman -S <pkg>" "Install package(s)"
    tbl_row "pacman -R <pkg>" "Remove package(s)"
    tbl_row "pacman -Rns <pkg>" "Remove pkg + deps + config"
    tbl_row "pacman -Q" "List installed packages"
    tbl_row "pacman -Qe" "List explicitly installed"
    tbl_row "pacman -Qdt" "List orphaned packages"
    tbl_row "pacman -F <file>" "Find which pkg owns file"
    tbl_row "pacman -Dk" "Check pkg database integrity"
    tbl_row "pacman -Sc" "Clean unused pkgs from cache"
    tbl_row "pacman -Scc" "Clean all cache (dangerous)"
    tbl_row "pacman -Sl" "List all available packages"
    tbl_row "pacman -Si <pkg>" "Show package info"
    tbl_row "pacman -Ql <pkg>" "List files owned by pkg"
    tbl_row "pacman -Qo <file>" "Find pkg that owns file"
    tbl_row "pacman -U <file.pkg.tar>" "Install local package file"
    draw_table_end

    # ─────────────────────────────────────────────────────────────────────────
    # GROUP 2: AUR HELPERS (YAY/PARU)
    # ─────────────────────────────────────────────────────────────────────────
    draw_section_header "2. AUR HELPERS (YAY/PARU)"

    draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
    tbl_row "yay -S <pkg>" "Install from AUR/official"
    tbl_row "yay -Syu" "Update all (AUR + official)"
    tbl_row "yay -Qm" "List AUR packages"
    tbl_row "yay -Rns <pkg>" "Remove AUR package"
    tbl_row "yay -Ps" "Show stats"
    tbl_row "yay -G <pkg>" "Download PKGBUILD only"
    tbl_row "yay -w <pkg>" "Download sources only"
    tbl_row "paru -S <pkg>" "Paru equivalent (same syntax)"
    draw_table_end

    # ─────────────────────────────────────────────────────────────────────────
    # GROUP 3: SYSTEM INFORMATION
    # ─────────────────────────────────────────────────────────────────────────
    draw_section_header "3. SYSTEM INFORMATION"

    draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
    tbl_row "uname -r" "Show kernel version"
    tbl_row "uname -a" "Show all system info"
    tbl_row "hostnamectl" "Show hostname & boot time"
    tbl_row "cat /etc/os-release" "Show distribution info"
    tbl_row "neofetch" "System info with ASCII art"
    tbl_row "fastfetch" "Faster neofetch alternative"
    tbl_row "lscpu" "CPU architecture info"
    tbl_row "nproc" "Number of CPU cores"
    tbl_row "free -h" "Memory usage (human readable)"
    tbl_row "df -h" "Disk space (human readable)"
    tbl_row "lsblk" "List block devices"
    tbl_row "blkid" "Show block device UUIDs"
    tbl_row "lsmod" "List loaded kernel modules"
    tbl_row "modinfo <mod>" "Show module information"
    tbl_row "inxi -Fza" "Full system info (detailed)"
    draw_table_end

    # ─────────────────────────────────────────────────────────────────────────
    # GROUP 4: PROCESS & SERVICE MANAGEMENT
    # ─────────────────────────────────────────────────────────────────────────
    draw_section_header "4. PROCESS & SERVICE MANAGEMENT"

    draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
    tbl_row "systemctl status" "Show systemd overview"
    tbl_row "systemctl list-units" "List active units"
    tbl_row "systemctl list-timers" "List systemd timers"
    tbl_row "systemctl start <svc>" "Start a service"
    tbl_row "systemctl stop <svc>" "Stop a service"
    tbl_row "systemctl restart <svc>" "Restart a service"
    tbl_row "systemctl enable <svc>" "Enable at boot"
    tbl_row "systemctl disable <svc>" "Disable at boot"
    tbl_row "systemctl daemon-reload" "Reload systemd config"
    tbl_row "journalctl -b" "Logs from current boot"
    tbl_row "journalctl -b -1" "Logs from previous boot"
    tbl_row "journalctl -f" "Follow logs (tail -f)"
    tbl_row "journalctl -u <svc>" "Logs for specific service"
    tbl_row "journalctl -p 3" "Show priority ≤ ERR"
    tbl_row "ps aux" "Show all processes"
    tbl_row "top" "Interactive process viewer"
    tbl_row "htop" "Enhanced top (if installed)"
    tbl_row "kill <PID>" "Terminate process"
    tbl_row "killall <name>" "Kill by process name"
    tbl_row "pkill <pattern>" "Kill by pattern"
    draw_table_end

    # ─────────────────────────────────────────────────────────────────────────
    # GROUP 5: HARDWARE DETECTION
    # ─────────────────────────────────────────────────────────────────────────
    draw_section_header "5. HARDWARE DETECTION"

    draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
    tbl_row "lspci" "List PCI devices"
    tbl_row "lspci -k" "PCI + kernel drivers"
    tbl_row "lspci -nn" "PCI with vendor IDs"
    tbl_row "lspci -v" "PCI verbose output"
    tbl_row "lsusb" "List USB devices"
    tbl_row "lsusb -t" "USB tree view"
    tbl_row "lsusb -v" "USB verbose output"
    tbl_row "lshw" "Hardware list (needs root)"
    tbl_row "lshw -short" "Short hardware summary"
    tbl_row "hwinfo" "Hardware info tool"
    tbl_row "dmidecode" "DMI/SMBIOS table dump"
    tbl_row "upower -i /dev" "Power/battery info"
    tbl_row "iwctl" "Wireless CLI tool"
    tbl_row "iwconfig" "Wireless config (legacy)"
    tbl_row "ip addr" "Show IP addresses"
    tbl_row "ip route" "Show routing table"
    draw_table_end

    # ─────────────────────────────────────────────────────────────────────────
    # GROUP 6: DISK & FILESYSTEM
    # ─────────────────────────────────────────────────────────────────────────
    draw_section_header "6. DISK & FILESYSTEM"

    draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
    tbl_row "fdisk -l" "List partitions"
    tbl_row "parted -l" "Partition table info"
    tbl_row "mkfs.<type> <dev>" "Create filesystem"
    tbl_row "mount <dev> <mnt>" "Mount device"
    tbl_row "umount <dev|mnt>" "Unmount device"
    tbl_row "findmnt" "Tree of mounted filesystems"
    tbl_row "cat /proc/mounts" "Active mounts list"
    tbl_row "du -sh <dir>" "Directory size"
    tbl_row "du -h --max-depth=1" "Subdir sizes"
    tbl_row "ncdu" "NCurses disk usage"
    tbl_row "btrfs filesystem usage" "Btrfs space info"
    tbl_row "fsck <dev>" "Filesystem check"
    tbl_row "smartctl -a <dev>" "SMART disk health"
    tbl_row "hdparm -Tt <dev>" "Disk speed test"
    draw_table_end

    # ─────────────────────────────────────────────────────────────────────────
    # GROUP 7: NETWORK DIAGNOSTICS
    # ─────────────────────────────────────────────────────────────────────────
    draw_section_header "7. NETWORK DIAGNOSTICS"

    draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
    tbl_row "ping <host>" "Test connectivity"
    tbl_row "ping -6 <host>" "IPv6 ping"
    tbl_row "traceroute <host>" "Trace network path"
    tbl_row "tracepath <host>" "Path MTU discovery"
    tbl_row "mtr <host>" "Ping + traceroute combo"
    tbl_row "dig <domain>" "DNS lookup"
    tbl_row "nslookup <domain>" "DNS query (legacy)"
    tbl_row "host <domain>" "Simple DNS lookup"
    tbl_row "curl <url>" "Transfer data from URL"
    tbl_row "wget <url>" "Download files"
    tbl_row "ss -tulpn" "Show listening ports"
    tbl_row "netstat -tulpn" "Netstat (legacy)"
    tbl_row "nmap <host>" "Network scanner"
    tbl_row "ip link" "Show network interfaces"
    tbl_row "ip neigh" "Show ARP table"
    tbl_row "resolvectl status" "DNS resolver status"
    draw_table_end

    # ─────────────────────────────────────────────────────────────────────────
    # GROUP 8: USER & PERMISSIONS
    # ─────────────────────────────────────────────────────────────────────────
    draw_section_header "8. USER & PERMISSIONS"

    draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
    tbl_row "id" "Show current user ID"
    tbl_row "whoami" "Show current username"
    tbl_row "users" "Logged in users"
    tbl_row "w" "Who + what they're doing"
    tbl_row "last" "Login history"
    tbl_row "lastb" "Failed login attempts"
    tbl_row "sudo -i" "Become root (interactive)"
    tbl_row "su - <user>" "Switch user"
    tbl_row "chmod <mode> <file>" "Change permissions"
    tbl_row "chown <user> <file>" "Change ownership"
    tbl_row "getfacl <file>" "Show ACL permissions"
    tbl_row "setfacl -m <rule>" "Set ACL permissions"
    tbl_row "passwd <user>" "Change password"
    tbl_row "groups <user>" "Show user groups"
    draw_table_end

    # ─────────────────────────────────────────────────────────────────────────
    # GROUP 9: LOGS & DEBUGGING
    # ─────────────────────────────────────────────────────────────────────────
    draw_section_header "9. LOGS & DEBUGGING"

    draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
    tbl_row "journalctl" "View systemd journal"
    tbl_row "journalctl -xe" "Journal + explanations"
    tbl_row "journalctl --disk-usage" "Journal disk usage"
    tbl_row "journalctl --vacuum" "Vacuum old journals"
    tbl_row "dmesg" "Kernel ring buffer"
    tbl_row "dmesg -w" "Follow kernel messages"
    tbl_row "coredumpctl list" "List core dumps"
    tbl_row "coredumpctl info" "Core dump details"
    tbl_row "strace <cmd>" "Trace syscalls"
    tbl_row "ltrace <cmd>" "Trace library calls"
    tbl_row "gdb <bin>" "GNU debugger"
    tbl_row "valgrind <cmd>" "Memory debugger"
    draw_table_end

    # ─────────────────────────────────────────────────────────────────────────
    # GROUP 10: ARCH-SPECIFIC UTILITIES
    # ─────────────────────────────────────────────────────────────────────────
    draw_section_header "10. ARCH-SPECIFIC UTILITIES"

    draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
    tbl_row "archlinux-keyring-wkd" "Update keyring"
    tbl_row "pacman-key --init" "Init pacman keyring"
    tbl_row "pacman-key --populate" "Populate keyring"
    tbl_row "reflector" "Mirrorlist generator"
    tbl_row "rankmirrors" "Rank mirrors by speed"
    tbl_row "makepkg -si" "Build PKGBUILD + install"
    tbl_row "makepkg --clean" "Clean build dir"
    tbl_row "pkgfile <cmd>" "Find pkg providing cmd"
    tbl_row "pactree <pkg>" "Show dependency tree"
    tbl_row "vercmp <v1> <v2>" "Compare versions"
    tbl_row "namcap <pkg>" "Package analyzer"
    tbl_row "debuginfod-find" "Find debug symbols"
    draw_table_end

    # ─────────────────────────────────────────────────────────────────────────
    # GROUP 11: PERFORMANCE & MONITORING
    # ─────────────────────────────────────────────────────────────────────────
    draw_section_header "11. PERFORMANCE & MONITORING"

    draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
    tbl_row "vmstat" "Virtual memory stats"
    tbl_row "iostat" "I/O statistics"
    tbl_row "mpstat" "CPU stats per core"
    tbl_row "sar" "System activity report"
    tbl_row "pidstat" "Per-process stats"
    tbl_row "iotop" "Disk I/O by process"
    tbl_row "nethogs" "Bandwidth by process"
    tbl_row "iftop" "Network bandwidth"
    tbl_row "perf top" "CPU profiling"
    tbl_row "powertop" "Power consumption"
    tbl_row "cpupower frequency-info" "CPU freq info"
    tbl_row "cpupower frequency-set" "Set CPU governor"
    draw_table_end

    # ─────────────────────────────────────────────────────────────────────────
    # GROUP 12: BACKUP & RECOVERY
    # ─────────────────────────────────────────────────────────────────────────
    draw_section_header "12. BACKUP & RECOVERY"

    draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
    tbl_row "rsync -av <src> <dst>" "Sync files/dirs"
    tbl_row "tar -czf <a.tar.gz>" "Create archive"
    tbl_row "tar -xzf <a.tar.gz>" "Extract archive"
    tbl_row "dd if=<in> of=<out>" "Block copy (careful!)"
    tbl_row "timeshift" "System snapshot tool"
    tbl_row "snapper list" "Btrfs snapshot list"
    tbl_row "fsarchiver" "Filesystem archiver"
    tbl_row "clonezilla" "Disk imaging tool"
    draw_table_end

    # ─────────────────────────────────────────────────────────────────────────
    # GROUP 13: TROUBLESHOOTING & DIAGNOSTICS
    # ─────────────────────────────────────────────────────────────────────────
    draw_section_header "13. TROUBLESHOOTING & DIAGNOSTICS"

    draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
    tbl_row "dmesg -T" "Kernel messages with timestamps"
    tbl_row "dmesg -l err" "Show only error messages"
    tbl_row "dmesg -l warn" "Show only warnings"
    tbl_row "journalctl -p err -b" "Errors from current boot"
    tbl_row "journalctl -p warning -b" "Warnings from current boot"
    tbl_row "systemctl --failed" "List failed services"
    tbl_row "systemctl is-failed <svc>" "Check if service failed"
    tbl_row "coredumpctl list" "List application crashes"
    tbl_row "coredumpctl gdb <exe>" "Debug crash with gdb"
    tbl_row "strace -p <PID>" "Trace running process"
    tbl_row "lsof -p <PID>" "List open files by PID"
    tbl_row "lsof -i :<port>" "Find process on port"
    tbl_row "fuser -v <file>" "Find processes using file"
    tbl_row "inxi -Fxxxz" "Full hardware info"
    tbl_row "hwinfo --short" "Hardware summary"
    draw_table_end

    # ─────────────────────────────────────────────────────────────────────────
    # GROUP 14: BOOT & STARTUP REPAIR
    # ─────────────────────────────────────────────────────────────────────────
    draw_section_header "14. BOOT & STARTUP REPAIR"

    draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
    tbl_row "bootctl status" "Check boot loader status"
    tbl_row "efibootmgr -v" "List EFI boot entries"
    tbl_row "grub-mkconfig -o /boot/grub..." "Regenerate GRUB config"
    tbl_row "mkinitcpio -P" "Regenerate initramfs"
    tbl_row "mkinitcpio -p linux" "Rebuild for specific kernel"
    tbl_row "pacman -S linux" "Reinstall kernel"
    tbl_row "arch-chroot /mnt" "Chroot into installed system"
    tbl_row "fstab-gen" "Generate fstab file"
    tbl_row "blkid" "Show block device UUIDs"
    tbl_row "lsblk -f" "List devices with filesystems"
    draw_table_end

    # ─────────────────────────────────────────────────────────────────────────
    # GROUP 15: MEMORY & SWAP
    # ─────────────────────────────────────────────────────────────────────────
    draw_section_header "15. MEMORY & SWAP"

    draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
    tbl_row "free -h" "Memory and swap usage"
    tbl_row "vmstat -s" "Memory statistics"
    tbl_row "swapon --show" "Show swap devices"
    tbl_row "swapon -a" "Enable all swap"
    tbl_row "swapoff -a" "Disable all swap"
    tbl_row "mkswap /dev/<part>" "Create swap space"
    tbl_row "zramctl" "ZRAM compression status"
    tbl_row "smem -tk" "Memory usage by process"
    tbl_row "pmap -x <PID>" "Process memory mapping"
    draw_table_end

    # ─────────────────────────────────────────────────────────────────────────
    # GROUP 16: GRAPHICS & DISPLAY
    # ─────────────────────────────────────────────────────────────────────────
    draw_section_header "16. GRAPHICS & DISPLAY"

    draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
    tbl_row "glxinfo -B" "OpenGL renderer info"
    tbl_row "glxgears" "OpenGL benchmark"
    tbl_row "vulkaninfo" "Vulkan GPU info"
    tbl_row "xrandr" "Display configuration"
    tbl_row "xrandr --query" "List connected displays"
    tbl_row "nvidia-smi" "NVIDIA GPU status"
    tbl_row "radeontop" "AMD GPU utilization"
    tbl_row "intel_gpu_top" "Intel GPU utilization"
    tbl_row "vainfo" "Video acceleration info"
    tbl_row "libinput list-devices" "Input devices info"
    draw_table_end

    # ─────────────────────────────────────────────────────────────────────────
    # GROUP 17: SOUND & AUDIO
    # ─────────────────────────────────────────────────────────────────────────
    draw_section_header "17. SOUND & AUDIO"

    draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
    tbl_row "pactl list short sinks" "List audio outputs"
    tbl_row "pactl list short sources" "List audio inputs"
    tbl_row "pactl info" "PulseAudio server info"
    tbl_row "pavucontrol" "PulseAudio volume control"
    tbl_row "alsamixer" "ALSA mixer interface"
    tbl_row "aplay -l" "List ALSA playback devices"
    tbl_row "arecord -l" "List ALSA capture devices"
    tbl_row "speaker-test -c 2" "Test stereo speakers"
    tbl_row "wireplumber" "PipeWire session manager"
    draw_table_end

    # ─────────────────────────────────────────────────────────────────────────
    # GROUP 18: SYSTEMD JOURNAL CONTROL
    # ─────────────────────────────────────────────────────────────────────────
    draw_section_header "18. SYSTEMD JOURNAL CONTROL"

    draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
    tbl_row "journalctl --list-boots" "List boot entries"
    tbl_row "journalctl -b -1" "Previous boot logs"
    tbl_row "journalctl -b -2" "Two boots ago logs"
    tbl_row "journalctl --since today" "Logs from today"
    tbl_row "journalctl --since 1h ago" "Last hour logs"
    tbl_row "journalctl -u <svc>" "Service-specific logs"
    tbl_row "journalctl -t <tag>" "Logs by identifier"
    tbl_row "journalctl -k" "Kernel-only logs"
    tbl_row "journalctl -f" "Follow logs (live)"
    tbl_row "journalctl --vacuum-time=7d" "Keep 7 days of logs"
    tbl_row "journalctl --disk-usage" "Journal disk usage"
    tbl_row "journalctl --rotate" "Force log rotation"
    draw_table_end

    # ─────────────────────────────────────────────────────────────────────────
    # GROUP 19: FILE & PERMISSION DEBUG
    # ─────────────────────────────────────────────────────────────────────────
    draw_section_header "19. FILE & PERMISSION DEBUG"

    draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
    tbl_row "stat <file>" "File metadata"
    tbl_row "ls -la <dir>" "List files with permissions"
    tbl_row "getfacl <file>" "Show ACL permissions"
    tbl_row "namei -l /path" "Trace path permissions"
    tbl_row "findmnt -D" "Find mount by device"
    tbl_row "lsof +D <dir>" "Open files in directory"
    tbl_row "fuser -vm <mount>" "Processes using mount"
    tbl_row "du -sh /*" "Top-level disk usage"
    tbl_row "ncdu" "Interactive disk usage"
    draw_table_end

    # ─────────────────────────────────────────────────────────────────────────
    # GROUP 20: EMERGENCY & RECOVERY
    # ─────────────────────────────────────────────────────────────────────────
    draw_section_header "20. EMERGENCY & RECOVERY"

    draw_table_begin "Command" "$col1_width" "Description" "$col2_width"
    tbl_row "systemctl emergency" "Enter emergency mode"
    tbl_row "systemctl rescue" "Enter rescue mode"
    tbl_row "mount -o remount,rw /" "Remount root as read-write"
    tbl_row "fsck -y /dev/<part>" "Auto-fix filesystem"
    tbl_row "test -x /file" "Test if file executable"
    tbl_row "pacman-key --refresh-keys" "Refresh package keys"
    tbl_row "pacman -Syyu" "Force full system upgrade"
    tbl_row "downgrade <pkg>" "Downgrade package (AUR)"
    draw_table_end

    printf '\n'
    draw_box_line "${C_GREEN}✓ For more: https://wiki.archlinux.org${C_RESET}"
    draw_box_line "${C_CYAN}Tip: Use 'man <command>' for detailed documentation${C_RESET}"
    draw_box_line "${C_YELLOW}Note: Some commands require root privileges${C_RESET}"
    draw_footer
    printf '\n'
}

show_help() {
    cat <<EOF
${C_BOLD}${SCRIPT_NAME}${C_RESET} - arlogkn

${C_CYAN}USAGE:${C_RESET}
    ${SCRIPT_NAME} [OPTIONS]

${C_CYAN}OPTIONS:${C_RESET}
    --all              Scan everything (default)
    --kernel           Only scan kernel ring buffer
    --user             Only scan user services
    --mount            Scan mounted filesystems and disk usage
    --usb              Scan USB devices and storage
    --driver           Scan driver status (GPU, Network, Audio)
    --vga              Scan GPU/VGA and display information
    --system           Full system scan (mount + USB + driver + VGA + system info)
    --wiki             Show all wiki groups
    --wiki <group>     Show specific wiki group (e.g., sound, graphics, boot)
    --boot=N           Check boot N (0=current, -1=previous, default: 0)
    --save             Export logs to separate files in ./arch-diag-logs/
    --save-all         Export all logs to single file in ./arch-diag-logs/
    --help, -h         Show this help
    --version, -v      Show version

${C_CYAN}EXAMPLES:${C_RESET}
    ${SCRIPT_NAME}                    # Full scan, current boot
    ${SCRIPT_NAME} --kernel --boot=-1 # Kernel errors from previous boot
    ${SCRIPT_NAME} --user             # Service failures only
    ${SCRIPT_NAME} --mount            # Show mounted filesystems
    ${SCRIPT_NAME} --usb              # Show USB devices
    ${SCRIPT_NAME} --driver           # Check driver status
    ${SCRIPT_NAME} --vga              # Show GPU/Display info
    ${SCRIPT_NAME} --system           # Full system scan (no logs)
    ${SCRIPT_NAME} --wiki             # Show all wiki groups
    ${SCRIPT_NAME} --wiki sound       # Show only sound & audio commands
    ${SCRIPT_NAME} --wiki graphics    # Show only graphics & display commands
    ${SCRIPT_NAME} --wiki boot        # Show only boot & startup repair
    ${SCRIPT_NAME} --wiki troubleshooting  # Show troubleshooting commands
    ${SCRIPT_NAME} --save             # Full scan + export to separate files
    ${SCRIPT_NAME} --save-all         # Full scan + export to single file
    ${SCRIPT_NAME} --save --system    # System scan + export to separate files
    ${SCRIPT_NAME} --save-all --system # System scan + export to single file

${C_CYAN}WIKI GROUPS:${C_RESET}
    pacman, aur, system, process, hardware, disk, network, user, logs,
    arch, performance, backup, troubleshooting, boot, memory, graphics,
    sound, systemd, file, emergency

${C_CYAN}NOTES:${C_RESET}
    - Read-only: No system modifications
    - Root access provides fuller log visibility
    - Groups identical errors to reduce noise
    - With --save: Creates timestamped directory with separate log files
    - With --save-all: Creates single consolidated log file (raw format)
    - Auto-detects internet connection status
    - Wiki supports fuzzy matching (e.g., 'soud' suggests 'sound')

EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN ENTRY POINT
# ─────────────────────────────────────────────────────────────────────────────

main() {
    parse_args "$@"
    init_colors
    detect_distro
    detect_system_info
    check_internet
    detect_gpu
    detect_display

    local width=70
    local boot_flag="-b $BOOT_OFFSET"

    # Header
    printf '\n'
    draw_header "ARLOGKN v${VERSION}"
    printf '\n'
    draw_info_box "System" "${DISTRO_NAME} (${DISTRO_TYPE})"
    draw_info_box "Kernel" "${KERNEL_VER}"
    draw_info_box "CPU Governor" "${CPU_GOVERNOR}"

    # Internet status
    if [[ "$INTERNET_STATUS" == "connected" ]]; then
        draw_info_box "Internet" "${C_GREEN}Connected${C_RESET}"
    else
        draw_info_box "Internet" "${C_RED}Disconnected${C_RESET}"
    fi

    # Boot offset description
    local boot_desc
    case "$BOOT_OFFSET" in
        0) boot_desc="current boot" ;;
        -1) boot_desc="previous boot" ;;
        *) boot_desc="boot #$BOOT_OFFSET" ;;
    esac
    draw_info_box "Boot Offset" "${BOOT_OFFSET} ($boot_desc)"
    draw_footer

    # Initialize output directory if --save or --save-all is set
    if [[ "$SAVE_LOGS" -eq 1 || "$SAVE_ALL" -eq 1 ]]; then
        if ! init_output_dir; then
            warn "Failed to create output directory. Continuing without export."
            SAVE_LOGS=0
            SAVE_ALL=0
        fi
    fi

    # Execute scans based on flags
    if [[ "$SCAN_ALL" -eq 1 ]]; then
        scan_system_basics
        scan_vga_info
        scan_drivers
        scan_kernel_logs "$boot_flag"
        scan_user_services "$boot_flag"
        scan_coredumps
        scan_pacman_logs
        scan_mounts
        scan_usb_devices

        # Export logs if --save is set (separate files)
        if [[ "$SAVE_LOGS" -eq 1 ]]; then
            printf '\n'
            draw_box_line "${C_CYAN}Exporting logs to ${OUTPUT_DIR}...${C_RESET}"
            draw_footer
            
            local export_failed=0
            
            export_kernel_logs "$boot_flag" || { warn "Export kernel logs failed"; export_failed=1; }
            export_user_services "$boot_flag" || { warn "Export user services failed"; export_failed=1; }
            export_coredumps || { warn "Export coredumps failed"; export_failed=1; }
            export_pacman_logs || { warn "Export pacman logs failed"; export_failed=1; }
            export_mounts || { warn "Export mounts failed"; export_failed=1; }
            export_usb_devices || { warn "Export USB devices failed"; export_failed=1; }
            export_vga_info || { warn "Export VGA info failed"; export_failed=1; }
            export_drivers || { warn "Export drivers failed"; export_failed=1; }
            export_summary "$boot_flag" || { warn "Export summary failed"; export_failed=1; }
            
            if [[ "$export_failed" -eq 1 ]]; then
                draw_box_line "${C_YELLOW}⚠ Some exports failed (check warnings above)${C_RESET}"
            else
                draw_box_line "${C_GREEN}✓ Export complete: ${OUTPUT_DIR}${C_RESET}"
            fi
            draw_footer
        # Export all logs if --save-all is set (single file)
        elif [[ "$SAVE_ALL" -eq 1 ]]; then
            printf '\n'
            draw_box_line "${C_CYAN}Exporting all logs to single file...${C_RESET}"
            draw_footer
            if export_all_logs "$boot_flag"; then
                draw_box_line "${C_GREEN}✓ Export complete: ${OUTPUT_DIR}/arch-log-inspector-all.txt${C_RESET}"
            else
                draw_box_line "${C_RED}✗ Export failed (check warnings above)${C_RESET}"
            fi
            draw_footer
        fi
    elif [[ "$SCAN_SYSTEM" -eq 1 ]]; then
        # --system flag: full system scan without logs
        scan_system_basics
        scan_vga_info
        scan_drivers
        scan_mounts
        scan_usb_devices

        if [[ "$SAVE_LOGS" -eq 1 ]]; then
            printf '\n'
            draw_box_line "${C_CYAN}Exporting logs to ${OUTPUT_DIR}...${C_RESET}"
            draw_footer
            
            local export_failed=0
            export_mounts || { warn "Export mounts failed"; export_failed=1; }
            export_usb_devices || { warn "Export USB devices failed"; export_failed=1; }
            export_vga_info || { warn "Export VGA info failed"; export_failed=1; }
            export_drivers || { warn "Export drivers failed"; export_failed=1; }
            export_summary "$boot_flag" || { warn "Export summary failed"; export_failed=1; }
            
            if [[ "$export_failed" -eq 1 ]]; then
                draw_box_line "${C_YELLOW}⚠ Some exports failed (check warnings above)${C_RESET}"
            else
                draw_box_line "${C_GREEN}✓ Export complete: ${OUTPUT_DIR}${C_RESET}"
            fi
            draw_footer
        elif [[ "$SAVE_ALL" -eq 1 ]]; then
            printf '\n'
            draw_box_line "${C_CYAN}Exporting all logs to single file...${C_RESET}"
            draw_footer
            if export_all_logs "$boot_flag"; then
                draw_box_line "${C_GREEN}✓ Export complete: ${OUTPUT_DIR}/arch-log-inspector-all.txt${C_RESET}"
            else
                draw_box_line "${C_RED}✗ Export failed (check warnings above)${C_RESET}"
            fi
            draw_footer
        fi
    elif [[ "$SCAN_WIKI" -eq 1 ]]; then
        # --wiki flag: show Arch Linux command wiki
        show_wiki
    elif [[ "$SCAN_DRIVER" -eq 1 ]]; then
        scan_drivers

        if [[ "$SAVE_LOGS" -eq 1 ]]; then
            printf '\n'
            draw_box_line "${C_CYAN}Exporting logs to ${OUTPUT_DIR}...${C_RESET}"
            draw_footer
            
            local export_failed=0
            export_drivers || { warn "Export drivers failed"; export_failed=1; }
            export_summary "$boot_flag" || { warn "Export summary failed"; export_failed=1; }
            
            if [[ "$export_failed" -eq 1 ]]; then
                draw_box_line "${C_YELLOW}⚠ Some exports failed (check warnings above)${C_RESET}"
            else
                draw_box_line "${C_GREEN}✓ Export complete: ${OUTPUT_DIR}${C_RESET}"
            fi
            draw_footer
        fi
    elif [[ "$SCAN_VGA" -eq 1 ]]; then
        scan_vga_info

        if [[ "$SAVE_LOGS" -eq 1 ]]; then
            printf '\n'
            draw_box_line "${C_CYAN}Exporting logs to ${OUTPUT_DIR}...${C_RESET}"
            draw_footer
            
            local export_failed=0
            export_vga_info || { warn "Export VGA info failed"; export_failed=1; }
            export_summary "$boot_flag" || { warn "Export summary failed"; export_failed=1; }
            
            if [[ "$export_failed" -eq 1 ]]; then
                draw_box_line "${C_YELLOW}⚠ Some exports failed (check warnings above)${C_RESET}"
            else
                draw_box_line "${C_GREEN}✓ Export complete: ${OUTPUT_DIR}${C_RESET}"
            fi
            draw_footer
        fi
    elif [[ "$SCAN_KERNEL" -eq 1 ]]; then
        scan_kernel_logs "$boot_flag"

        if [[ "$SAVE_LOGS" -eq 1 ]]; then
            printf '\n'
            draw_box_line "${C_CYAN}Exporting logs to ${OUTPUT_DIR}...${C_RESET}"
            draw_footer
            
            local export_failed=0
            export_kernel_logs "$boot_flag" || { warn "Export kernel logs failed"; export_failed=1; }
            export_summary "$boot_flag" || { warn "Export summary failed"; export_failed=1; }
            
            if [[ "$export_failed" -eq 1 ]]; then
                draw_box_line "${C_YELLOW}⚠ Some exports failed (check warnings above)${C_RESET}"
            else
                draw_box_line "${C_GREEN}✓ Export complete: ${OUTPUT_DIR}${C_RESET}"
            fi
            draw_footer
        fi
    elif [[ "$SCAN_USER" -eq 1 ]]; then
        scan_user_services "$boot_flag"
        scan_coredumps

        if [[ "$SAVE_LOGS" -eq 1 ]]; then
            printf '\n'
            draw_box_line "${C_CYAN}Exporting logs to ${OUTPUT_DIR}...${C_RESET}"
            draw_footer
            
            local export_failed=0
            export_user_services "$boot_flag" || { warn "Export user services failed"; export_failed=1; }
            export_coredumps || { warn "Export coredumps failed"; export_failed=1; }
            export_summary "$boot_flag" || { warn "Export summary failed"; export_failed=1; }
            
            if [[ "$export_failed" -eq 1 ]]; then
                draw_box_line "${C_YELLOW}⚠ Some exports failed (check warnings above)${C_RESET}"
            else
                draw_box_line "${C_GREEN}✓ Export complete: ${OUTPUT_DIR}${C_RESET}"
            fi
            draw_footer
        fi
    elif [[ "$SCAN_MOUNT" -eq 1 && "$SCAN_USB" -eq 1 ]]; then
        # --system flag: mount + USB only
        scan_mounts
        scan_usb_devices

        if [[ "$SAVE_LOGS" -eq 1 ]]; then
            printf '\n'
            draw_box_line "${C_CYAN}Exporting logs to ${OUTPUT_DIR}...${C_RESET}"
            draw_footer
            
            local export_failed=0
            export_mounts || { warn "Export mounts failed"; export_failed=1; }
            export_usb_devices || { warn "Export USB devices failed"; export_failed=1; }
            export_summary "$boot_flag" || { warn "Export summary failed"; export_failed=1; }
            
            if [[ "$export_failed" -eq 1 ]]; then
                draw_box_line "${C_YELLOW}⚠ Some exports failed (check warnings above)${C_RESET}"
            else
                draw_box_line "${C_GREEN}✓ Export complete: ${OUTPUT_DIR}${C_RESET}"
            fi
            draw_footer
        fi
    elif [[ "$SCAN_MOUNT" -eq 1 ]]; then
        scan_mounts

        if [[ "$SAVE_LOGS" -eq 1 ]]; then
            printf '\n'
            draw_box_line "${C_CYAN}Exporting logs to ${OUTPUT_DIR}...${C_RESET}"
            draw_footer
            
            local export_failed=0
            export_mounts || { warn "Export mounts failed"; export_failed=1; }
            export_summary "$boot_flag" || { warn "Export summary failed"; export_failed=1; }
            
            if [[ "$export_failed" -eq 1 ]]; then
                draw_box_line "${C_YELLOW}⚠ Some exports failed (check warnings above)${C_RESET}"
            else
                draw_box_line "${C_GREEN}✓ Export complete: ${OUTPUT_DIR}${C_RESET}"
            fi
            draw_footer
        fi
    elif [[ "$SCAN_USB" -eq 1 ]]; then
        scan_usb_devices

        if [[ "$SAVE_LOGS" -eq 1 ]]; then
            printf '\n'
            draw_box_line "${C_CYAN}Exporting logs to ${OUTPUT_DIR}...${C_RESET}"
            draw_footer
            
            local export_failed=0
            export_usb_devices || { warn "Export USB devices failed"; export_failed=1; }
            export_summary "$boot_flag" || { warn "Export summary failed"; export_failed=1; }
            
            if [[ "$export_failed" -eq 1 ]]; then
                draw_box_line "${C_YELLOW}⚠ Some exports failed (check warnings above)${C_RESET}"
            else
                draw_box_line "${C_GREEN}✓ Export complete: ${OUTPUT_DIR}${C_RESET}"
            fi
            draw_footer
        fi
    fi

    # Footer
    printf '\n'
    draw_box_line "${C_GREEN}✓ Scan complete. This tool is read-only.${C_RESET}"
    draw_footer
    printf '\n'
}

main "$@"

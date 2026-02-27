#!/usr/bin/env bash
# file: arch-diag.sh
# arlogkn - Read-only diagnostic tool
# Dependencies: bash 5.0+, coreutils, util-linux, systemd, awk, sed, grep

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# GLOBALS & CONFIG
# ─────────────────────────────────────────────────────────────────────────────
readonly VERSION="1.0.2"
readonly SCRIPT_NAME="$(basename "$0")"

# Color state (set dynamically)
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

# Distro info
declare -g DISTRO_NAME="Unknown"
declare -g DISTRO_TYPE="Generic"
declare -g KERNEL_VER=""
declare -g CPU_GOVERNOR="unknown"
declare -g GPU_INFO=""
declare -g DISPLAY_INFO=""

# Performance caches (avoid redundant system calls)
declare -g _DRIVERS_CACHE=""
declare -g _LSPCI_CACHE=""
declare -g _LSPCI_CACHE_INIT=0
declare -g _LSPCI_KNN_CACHE=""
declare -g _LSPCI_KNN_CACHE_INIT=0

# ─────────────────────────────────────────────────────────────────────────────
# UTILITY FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────

# Get lspci output with caching (single call per session)
_get_lspci() {
    if [[ "$_LSPCI_CACHE_INIT" -eq 0 ]]; then
        _LSPCI_CACHE="$(lspci -k 2>/dev/null || true)"
        _LSPCI_CACHE_INIT=1
    fi
    printf '%s' "$_LSPCI_CACHE"
}

# Get lspci -knn output with caching (for export)
_get_lspci_knn() {
    if [[ "$_LSPCI_KNN_CACHE_INIT" -eq 0 ]]; then
        _LSPCI_KNN_CACHE="$(lspci -knn 2>/dev/null || true)"
        _LSPCI_KNN_CACHE_INIT=1
    fi
    printf '%s' "$_LSPCI_KNN_CACHE"
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
# DISTRO & SYSTEM FINGERPRINTING
# ─────────────────────────────────────────────────────────────────────────────

detect_distro() {
    local id="" variant=""

    if [[ -f /etc/os-release ]]; then
        # Parse ID and ID_LIKE from os-release
        # -m1: only first match (avoid multi-line edge case)
        # -f2-: keep rest of line if value contains '='
        id="$(grep -m1 '^ID=' /etc/os-release | cut -d'=' -f2- | tr -d '"')"
        variant="$(grep -m1 '^ID_LIKE=' /etc/os-release | cut -d'=' -f2- | tr -d '"' || echo "")"
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
            # Use bash built-in for portability (avoid GNU sed \u extension)
            DISTRO_NAME="${id^}"
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
        # Parse governor from cpupower output format:
        #   The governor "performance" may decide which speed to use
        # NOT from "current policy: frequency..." line (wrong format)
        CPU_GOVERNOR="$(cpupower frequency-info 2>/dev/null | \
            sed -n 's/.*The governor "\([^"]*\)".*/\1/p' | head -1)"
        CPU_GOVERNOR="${CPU_GOVERNOR:-unknown}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# HARDWARE & SYSTEM DETECTION
# ─────────────────────────────────────────────────────────────────────────────

check_internet() {
    # Check internet connection (try both ping and curl independently)
    if command -v ping &>/dev/null; then
        if ping -c1 -W2 8.8.8.8 &>/dev/null; then
            INTERNET_STATUS="connected"
            return 0
        fi
    fi
    if command -v curl &>/dev/null; then
        # Use Google's captive portal endpoint (returns 204 No Content, empty body)
        # --head: fetch headers only (~500 bytes vs ~100KB full page)
        # --max-time 5: prevent slow downloads/timeouts
        # Location header indicates redirect to localized Google (confirms connectivity)
        if curl -s --head --connect-timeout 2 --max-time 5 \
             -o /dev/null -w '%{http_code}' https://www.google.com &>/dev/null; then
            INTERNET_STATUS="connected"
            return 0
        fi
        # Fallback: try Android captive portal endpoint (designed for connectivity checks)
        if curl -s --connect-timeout 2 --max-time 5 \
             https://clients3.google.com/generate_204 &>/dev/null; then
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
    for card_path in /sys/class/drm/card[0-9]*; do
        [[ ! -d "$card_path" ]] && continue
        
        # Skip render nodes and connector entries (e.g., card0-HDMI-A-1)
        [[ "$card_path" == *"render"* ]] && continue
        [[ "$(basename "$card_path")" == *-* ]] && continue
        
        driver=""
        if [[ -L "${card_path}/device/driver" ]]; then
            driver="$(readlink "${card_path}/device/driver" 2>/dev/null | xargs -r basename 2>/dev/null)"
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
        # Combined sed expressions: remove trailing comma, then add space after commas
        GPU_INFO="$(printf '%s\n' "${gpu_names[@]}" | sort -u | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
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
    local display_parts=()
    shopt -s nullglob
    for connector in /sys/class/drm/card*/card*-*/status; do
        [[ ! -f "$connector" ]] && continue
        status="$(cat "$connector" 2>/dev/null)"
        if [[ "$status" == "connected" ]]; then
            local name connector_dir
            connector_dir="$(dirname "$connector")"
            name="$(basename "$connector_dir")"
            name="${name#card*-}"  # Remove "card*-" prefix

            # Get resolution from THIS connector's modes file
            local res=""
            local modes_file="${connector_dir}/modes"
            if [[ -f "$modes_file" ]]; then
                res="$(head -1 "$modes_file" 2>/dev/null)"
            fi

            local entry="${name}"
            [[ -n "$res" ]] && entry="${entry} ($res)"
            display_parts+=("$entry")
        fi
    done
    shopt -u nullglob

    if [[ ${#display_parts[@]} -gt 0 ]]; then
        DISPLAY_INFO="$(printf '%s, ' "${display_parts[@]}")"
        DISPLAY_INFO="${DISPLAY_INFO%, }"  # Remove trailing comma+space
        return 0
    fi

    # Fallback: check if any DRM device exists
    if ls /sys/class/drm/card* &>/dev/null; then
        DISPLAY_INFO="DRM active (no connected display)"
        return 0
    fi

    DISPLAY_INFO="No display detected"
}

# ─────────────────────────────────────────────────────────────────────────────
# COMPREHENSIVE DRIVER DETECTION
# ─────────────────────────────────────────────────────────────────────────────

# Helper: Get driver from /sys/class device link
get_driver_from_sys() {
    local class_path="$1"
    local driver=""
    
    if [[ -L "${class_path}/device/driver" ]]; then
        driver="$(readlink "${class_path}/device/driver" 2>/dev/null | xargs -r basename 2>/dev/null)"
    fi
    echo "$driver"
}

# Main driver detection - multi-source comprehensive
detect_drivers() {
    # Return cached result if available (drivers don't change during session)
    [[ -n "$_DRIVERS_CACHE" ]] && echo "$_DRIVERS_CACHE" && return 0

    local lsmod_output
    lsmod_output="$(lsmod 2>/dev/null)" || true
    # Count loaded modules (skip header line)
    # Use NR>1{count++} to avoid -1 on empty input (awk with 0 bytes → NR=0 → NR-1=-1)
    # count+0 ensures 0 is printed even if count is unset (empty input)
    local loaded_count
    loaded_count="$(awk 'NR>1{count++} END{print count+0}' <<< "$lsmod_output")"
    
    # Initialize all driver variables
    local gpu_driver="N/A" network_driver="N/A" audio_driver="N/A"
    local storage_driver="N/A" usb_driver="N/A" thunderbolt_driver="N/A"
    local input_driver="N/A" platform_driver="N/A" virtual_driver="N/A"
    local nvme_driver="N/A" sata_driver="N/A" raid_driver="N/A"
    local i2c_driver="N/A" smbus_driver="N/A" watchdog_driver="N/A"
    
    # ─────────────────────────────────────────────────────────────────────────
    # SOURCE 1: /sys/class detection (most reliable)
    # ─────────────────────────────────────────────────────────────────────────

    # GPU from DRM (nullglob prevents literal pattern if no matches)
    if [[ -d /sys/class/drm ]]; then
        shopt -s nullglob
        local card_path driver
        for card_path in /sys/class/drm/card[0-9]*; do
            [[ ! -d "$card_path" ]] && continue
            [[ "$(basename "$card_path")" == *-* ]] && continue
            driver="$(get_driver_from_sys "$card_path")"
            [[ -n "$driver" && "$driver" != "N/A" ]] && gpu_driver="$driver"
        done
        shopt -u nullglob
    fi

    # Network from net class
    if [[ -d /sys/class/net ]]; then
        shopt -s nullglob
        local net_path iface_driver
        local -a net_drvs=()
        for net_path in /sys/class/net/*; do
            [[ ! -d "$net_path" ]] && continue
            [[ "$(basename "$net_path")" == "lo" ]] && continue
            iface_driver="$(get_driver_from_sys "$net_path")"
            if [[ -n "$iface_driver" && "$iface_driver" != "N/A" ]]; then
                # Avoid duplicates
                local dup=0
                # Use ${array[@]+"${array[@]}"} to handle empty array with set -u
                for d in "${net_drvs[@]+"${net_drvs[@]}"}"; do
                    [[ "$d" == "$iface_driver" ]] && dup=1 && break
                done
                [[ "$dup" -eq 0 ]] && net_drvs+=("$iface_driver")
            fi
        done
        shopt -u nullglob
        
        if [[ ${#net_drvs[@]} -gt 0 ]]; then
            network_driver="$(printf '%s, ' "${net_drvs[@]}")"
            network_driver="${network_driver%, }"
        fi
    fi

    # Audio from sound class
    if [[ -d /sys/class/sound ]]; then
        shopt -s nullglob
        local sound_path audio_drv
        for sound_path in /sys/class/sound/*; do
            [[ ! -d "$sound_path" ]] && continue
            audio_drv="$(get_driver_from_sys "$sound_path")"
            [[ -n "$audio_drv" && "$audio_drv" != "N/A" ]] && audio_driver="$audio_drv" && break
        done
        shopt -u nullglob
    fi
    
    # ─────────────────────────────────────────────────────────────────────────
    # SOURCE 2: lspci -k fallback/enhancement
    # ─────────────────────────────────────────────────────────────────────────

    if command -v lspci &>/dev/null; then
        # Use cached lspci output (single subprocess per session)
        local lspci_output
        lspci_output="$(_get_lspci)"

        # GPU (enhanced patterns)
        [[ "$gpu_driver" == "N/A" ]] && gpu_driver="$(echo "$lspci_output" | grep -A2 -iE 'vga|3d|display' | grep 'Kernel driver' | head -1 | cut -d':' -f2 | sed 's/^ *//')"
        
        # Network (enhanced patterns)
        [[ "$network_driver" == "N/A" ]] && network_driver="$(echo "$lspci_output" | grep -A2 -iE 'ethernet|network|wireless|wifi' | grep 'Kernel driver' | head -1 | cut -d':' -f2 | sed 's/^ *//')"
        
        # Audio
        [[ "$audio_driver" == "N/A" ]] && audio_driver="$(echo "$lspci_output" | grep -A2 -iE 'audio|hdmi|hd-audio' | grep 'Kernel driver' | head -1 | cut -d':' -f2 | sed 's/^ *//')"
        
        # Storage controllers
        storage_driver="$(echo "$lspci_output" | grep -A2 -iE 'sata|ahci|ide|storage' | grep 'Kernel driver' | head -1 | cut -d':' -f2 | sed 's/^ *//')"
        [[ -z "$storage_driver" ]] && storage_driver="N/A"
        
        # NVMe
        nvme_driver="$(echo "$lspci_output" | grep -A2 -iE 'nvme' | grep 'Kernel driver' | head -1 | cut -d':' -f2 | sed 's/^ *//')"
        [[ -z "$nvme_driver" ]] && nvme_driver="N/A"
        
        # USB Controller
        usb_driver="$(echo "$lspci_output" | grep -A2 -iE 'usb|xhci|ehci|ohci|uhci' | grep 'Kernel driver' | head -1 | cut -d':' -f2 | sed 's/^ *//')"
        [[ -z "$usb_driver" ]] && usb_driver="N/A"
        
        # Thunderbolt
        thunderbolt_driver="$(echo "$lspci_output" | grep -A2 -iE 'thunderbolt' | grep 'Kernel driver' | head -1 | cut -d':' -f2 | sed 's/^ *//')"
        [[ -z "$thunderbolt_driver" ]] && thunderbolt_driver="N/A"
        
        # I2C/SMBus
        smbus_driver="$(echo "$lspci_output" | grep -A2 -iE 'smbus|i2c' | grep 'Kernel driver' | head -1 | cut -d':' -f2 | sed 's/^ *//')"
        [[ -z "$smbus_driver" ]] && smbus_driver="N/A"

        # ISA/LPC Bridge (platform)
        # Prioritize ISA/LPC matches (specific platform bridges), then fallback to PCH/platform
        # Avoid generic 'bridge' pattern which matches PCIe/SATA bridges incorrectly
        platform_driver="$(echo "$lspci_output" | grep -A2 -iE 'isa bridge|lpc bridge|isa|lpc' | grep 'Kernel driver' | head -1 | cut -d':' -f2 | sed 's/^ *//')"
        if [[ -z "$platform_driver" ]]; then
            platform_driver="$(echo "$lspci_output" | grep -A2 -iE 'platform|pch' | grep 'Kernel driver' | head -1 | cut -d':' -f2 | sed 's/^ *//')"
        fi
        [[ -z "$platform_driver" ]] && platform_driver="N/A"
    fi
    
    # ─────────────────────────────────────────────────────────────────────────
    # SOURCE 3: /sys/bus detection
    # ─────────────────────────────────────────────────────────────────────────

    # Virtual drivers from /sys/bus/pci/drivers
    if [[ -d /sys/bus/pci/drivers ]]; then
        shopt -s nullglob
        for drv_dir in /sys/bus/pci/drivers/*; do
            local drv_name
            drv_name="$(basename "$drv_dir")"
            case "$drv_name" in
                virtio_*|virtio-pci) virtual_driver="virtio" ;;
                vmwgfx) virtual_driver="vmware" ;;
                vboxvideo|vboxguest) virtual_driver="virtualbox" ;;
                xen-*|xenplatform) virtual_driver="xen" ;;
            esac
        done
        shopt -u nullglob
    fi

    # Input drivers from /sys/class/input
    if [[ -d /sys/class/input ]]; then
        shopt -s nullglob
        local -a input_drvs=()
        local input_path
        for input_path in /sys/class/input/*; do
            [[ ! -d "$input_path" ]] && continue
            local inp_drv
            inp_drv="$(get_driver_from_sys "$input_path")"
            if [[ -n "$inp_drv" && "$inp_drv" != "N/A" ]]; then
                # Check for duplicates (same pattern as network drivers)
                local dup=0
                # Use ${array[@]+"${array[@]}"} to handle empty array with set -u
                for d in "${input_drvs[@]+"${input_drvs[@]}"}"; do
                    [[ "$d" == "$inp_drv" ]] && dup=1 && break
                done
                [[ "$dup" -eq 0 ]] && input_drvs+=("$inp_drv")
            fi
        done
        shopt -u nullglob
        # Join unique drivers with ", "
        if [[ ${#input_drvs[@]} -gt 0 ]]; then
            input_driver="$(printf '%s, ' "${input_drvs[@]}")"
            input_driver="${input_driver%, }"
        fi
    fi

    # Watchdog
    if [[ -d /sys/class/watchdog ]]; then
        shopt -s nullglob
        local wd_path
        for wd_path in /sys/class/watchdog/*; do
            [[ ! -d "$wd_path" ]] && continue
            local wd_drv
            wd_drv="$(get_driver_from_sys "$wd_path")"
            [[ -n "$wd_drv" && "$wd_drv" != "N/A" ]] && watchdog_driver="$wd_drv" && break
        done
        shopt -u nullglob
        [[ -z "$watchdog_driver" || "$watchdog_driver" == "N/A" ]] && watchdog_driver="N/A"
    fi
    
    # ─────────────────────────────────────────────────────────────────────────
    # SOURCE 4: lsmod category detection
    # ─────────────────────────────────────────────────────────────────────────
    
    # RAID detection
    if echo "$lsmod_output" | grep -qE '^raid|^dm_raid'; then
        raid_driver="mdraid/dm-raid"
    else
        raid_driver="N/A"
    fi
    
    # SATA enhancement
    if [[ "$sata_driver" == "N/A" ]] && echo "$lsmod_output" | grep -qE '^ahci|^sata_'; then
        sata_driver="$(echo "$lsmod_output" | grep -E '^ahci|^sata_' | head -1 | awk '{print $1}')"
        [[ -z "$sata_driver" ]] && sata_driver="N/A"
    fi
    
    # I2C enhancement
    if [[ "$i2c_driver" == "N/A" ]] && echo "$lsmod_output" | grep -qE '^i2c_'; then
        i2c_driver="$(echo "$lsmod_output" | grep -E '^i2c_' | head -1 | awk '{print $1}')"
        [[ -z "$i2c_driver" ]] && i2c_driver="N/A"
    fi
    
    # Set defaults for any remaining empty values
    [[ -z "$gpu_driver" ]] && gpu_driver="N/A"
    [[ -z "$network_driver" ]] && network_driver="N/A"
    [[ -z "$audio_driver" ]] && audio_driver="N/A"
    [[ -z "$storage_driver" ]] && storage_driver="N/A"
    [[ -z "$usb_driver" ]] && usb_driver="N/A"
    [[ -z "$thunderbolt_driver" ]] && thunderbolt_driver="N/A"
    [[ -z "$input_driver" ]] && input_driver="N/A"
    [[ -z "$platform_driver" ]] && platform_driver="N/A"
    [[ -z "$virtual_driver" ]] && virtual_driver="N/A"
    [[ -z "$nvme_driver" ]] && nvme_driver="N/A"
    [[ -z "$sata_driver" ]] && sata_driver="N/A"
    [[ -z "$raid_driver" ]] && raid_driver="N/A"
    [[ -z "$i2c_driver" ]] && i2c_driver="N/A"
    [[ -z "$watchdog_driver" ]] && watchdog_driver="N/A"

    # Sanitize driver names: remove '|' to prevent IFS parsing issues
    # (unlikely but possible with garbage in /sys or unusual module names)
    gpu_driver="${gpu_driver//|/_}"
    network_driver="${network_driver//|/_}"
    audio_driver="${audio_driver//|/_}"
    storage_driver="${storage_driver//|/_}"
    usb_driver="${usb_driver//|/_}"
    thunderbolt_driver="${thunderbolt_driver//|/_}"
    input_driver="${input_driver//|/_}"
    platform_driver="${platform_driver//|/_}"
    virtual_driver="${virtual_driver//|/_}"
    nvme_driver="${nvme_driver//|/_}"
    sata_driver="${sata_driver//|/_}"
    raid_driver="${raid_driver//|/_}"
    i2c_driver="${i2c_driver//|/_}"
    smbus_driver="${smbus_driver//|/_}"
    watchdog_driver="${watchdog_driver//|/_}"

    # Build result string (pipe-separated for IFS parsing)
    local result
    result="$(printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$loaded_count" \
        "$gpu_driver" "$network_driver" "$audio_driver" \
        "$storage_driver" "$usb_driver" "$thunderbolt_driver" \
        "$input_driver" "$platform_driver" "$virtual_driver" \
        "$nvme_driver" "$sata_driver" "$raid_driver" \
        "$i2c_driver" "$smbus_driver" "$watchdog_driver")"

    # Cache result for session (drivers don't change during run)
    _DRIVERS_CACHE="$result"
    echo "$result"
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
    local msg_len
    msg_len=$(visible_len "$message")
    local padding=$((width - msg_len))
    local half_pad=$((padding / 2))
    local remainder=$((padding - half_pad))

    printf '%*s%s%s%s%*s\n' "$half_pad" "" "$C_GREEN" "$message" "$C_RESET" "$remainder" ""
}

# draw_footer() removed — was no-op, eliminated 28 function calls for performance

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

    printf ' %s%s%*s%s\n' "$C_BOLD" "$full_line" "$padding" "" "$C_RESET"
}

# ─────────────────────────────────────────────────────────────────────────────
# TABLE DRAWING UTILITIES (Clean, minimal borders, ANSI-aware)
# ─────────────────────────────────────────────────────────────────────────────

# Strip ANSI codes (script variables + raw escape sequences)
# Uses pure bash to avoid subshell overhead in tight loops (table rendering)
strip_ansi() {
    local s="$1"
    # Strip script color variables
    s="${s//${C_RED}/}"
    s="${s//${C_GREEN}/}"
    s="${s//${C_YELLOW}/}"
    s="${s//${C_BLUE}/}"
    s="${s//${C_CYAN}/}"
    s="${s//${C_BOLD}/}"
    s="${s//${C_RESET}/}"
    # Strip raw ANSI escape sequences using bash regex (no subshell)
    # Pattern: ESC [ params... letter
    while [[ "$s" =~ $'\x1b''\['[0-9\;]*[a-zA-Z] ]]; do
        s="${s//"${BASH_REMATCH[0]}"/}"
    done
    printf '%s' "$s"
}

# Get visible length (excluding ANSI codes)
# Calls strip_ansi() for maintainability — single source of truth
# Subshell overhead is acceptable (~100μs per call, table rendering is not hot path)
visible_len() {
    local s="$1"
    local stripped
    stripped="$(strip_ansi "$s")"
    printf '%d' "${#stripped}"
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
        _TBL_WIDTH=$((_TBL_WIDTH + ${_TBL_COLS[$((i*2+1))]} + 1))
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
        local display_val="$val"
        
        # Truncate if too long (strip ANSI for truncation, but lose color)
        if [[ $vlen -gt $width ]]; then
            local clean
            clean=$(strip_ansi "$val")
            display_val="${clean:0:$((width-3))}..."
            vlen=$width
        fi
        
        local pad=$((width - vlen))
        printf ' %s%*s' "$display_val" "$pad" ""
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
        sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:?[0-9]{2} [^ ]+ //' | \
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
    local -a boot_args=(-b "$BOOT_OFFSET")
    local output=""
    local journal_output=""

    draw_section_header "KERNEL CRITICAL"

    # Check journal accessibility
    # We only want to warn if accessibility is restricted (e.g., EACCES).
    local jctl_err
    jctl_err="$(mktemp)" || { warn "Cannot create temp file for journal check"; return 1; }
    # Use trap EXIT instead of RETURN: EXIT fires on set -e termination, RETURN does not
    # This prevents temp file leak if script is killed mid-function
    trap 'rm -f "$jctl_err" 2>/dev/null' EXIT
    if ! timeout 10 journalctl -n 1 --quiet 2>"$jctl_err"; then
        if grep -q 'Permission denied\|Failed to open' "$jctl_err" 2>/dev/null; then
            warn "Cannot access system journal (try running as root for full access)"
        fi
    fi
    # Temp file no longer needed — delete immediately, then clear trap
    rm -f "$jctl_err" 2>/dev/null
    trap - EXIT

    # Fetch kernel errors (priority 3 = ERR)
    journal_output="$(timeout 10 journalctl -k -p 3 "${boot_args[@]}" --no-pager 2>/dev/null)" || true

    if [[ -z "$journal_output" ]]; then
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
    local info_line="${C_BLUE}Boot:${C_RESET} ${boot_args[*]} ${C_BLUE}|${C_RESET} First: $first_ts"
    draw_box_line "$info_line"

    # Separator line
    draw_box_line ""

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

        printf '%s\n' "$failed_output" | head -10 | while read -r unit load active sub description; do
            [[ -z "$unit" ]] && continue
            draw_box_line "  ${C_RED}●${C_RESET} ${C_BOLD}${unit}${C_RESET} — ${C_YELLOW}${sub}${C_RESET} (${description})"
        done

        local failed_count
        failed_count="$(printf '%s\n' "$failed_output" | wc -l)"
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
    printf '%s%*s\n' "$C_CYAN" 64 "" "$C_RESET"

    journal_output="$(timeout 10 journalctl -u "*.service" -p 3 "${boot_args[@]}" --no-pager 2>/dev/null)" || true

    if [[ -z "$journal_output" ]]; then
        draw_empty_box
        return 0
    fi

    output="$(cluster_errors "$journal_output")"

    if [[ -z "$output" ]]; then
        draw_empty_box
        return 0
    fi

    # Header info
    draw_box_line "${C_BOLD}Service Journal Errors (current boot)${C_RESET}"
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

    printf '%s\n' "$coredumps" | while read -r line; do
        # Parse coredumpctl output robustly
        # Format varies by systemd version.
        # Check if line has enough fields. If NF < 6, fallback to raw string.
        # Use printf to avoid echo interpreting flags like -n, -e in $line
        if ! printf '%s\n' "$line" | awk '{if(NF<6) exit 1}'; then
            draw_box_line "${C_YELLOW}$line${C_RESET}"
            continue
        fi

        # Extract fields using awk (single pass, handles multi-word timestamps)
        # coredumpctl format: TIME... PID UID GID SIG COREFILE EXE SIZE
        # Time can be multiple words: "Wed 2024-01-10 10:23:45 UTC"
        # Using awk directly avoids read splitting on whitespace
        local formatted
        formatted="$(awk -v cyan="$C_CYAN" -v rst="$C_RESET" -v bold="$C_BOLD" -v yellow="$C_YELLOW" '{
            # Build time string (all fields except last 7)
            time = ""
            for(i=1; i<=NF-7; i++) time = time (i>1 ? " " : "") $i
            # Extract fixed-position fields from end
            pid = $(NF-6)
            sig = $(NF-3)
            exe = $(NF-1)
            # Output formatted string
            printf "%s[%s]%s PID %s%s%s - %s%s%s (signal: %s)\n", \
                cyan, time, rst, bold, pid, rst, yellow, exe, rst, sig
        }' <<< "$line")"
        draw_box_line "$formatted"
    done

}

scan_pacman_logs() {
    draw_section_header "PACMAN / ALPM (Errors & Warnings)"

    local pacman_log="/var/log/pacman.log"

    if [[ ! -f "$pacman_log" ]]; then
        draw_box_line "${C_YELLOW}Pacman log not found (may require root)${C_RESET}"
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

}

# ─────────────────────────────────────────────────────────────────────────────
# HARDWARE TEMPERATURE SCANNING (zero-dependency, /sys/class/hwmon)
# ─────────────────────────────────────────────────────────────────────────────

scan_temperatures() {
    draw_section_header "HARDWARE TEMPERATURES"
    printf '\n'

    if [[ ! -d /sys/class/hwmon ]]; then
        draw_box_line "${C_YELLOW}hwmon subsystem not available${C_RESET}"
        return 0
    fi

    local found=0
    draw_table_begin "Sensor" 30 "Temperature" 18

    shopt -s nullglob
    for hwmon_dir in /sys/class/hwmon/hwmon*; do
        [[ ! -d "$hwmon_dir" ]] && continue

        # Get chip name
        local chip_name=""
        if [[ -f "${hwmon_dir}/name" ]]; then
            chip_name="$(cat "${hwmon_dir}/name" 2>/dev/null)"
        fi

        for temp_input in "${hwmon_dir}"/temp*_input; do
            [[ ! -f "$temp_input" ]] && continue

            local temp_raw label temp_c color
            temp_raw="$(cat "$temp_input" 2>/dev/null)" || continue
            [[ -z "$temp_raw" || ! "$temp_raw" =~ ^-?[0-9]+$ ]] && continue

            # Convert millidegrees to degrees
            temp_c=$((temp_raw / 1000))

            # Get label (e.g. "Core 0", "Tctl")
            local label_file="${temp_input%_input}_label"
            if [[ -f "$label_file" ]]; then
                label="$(cat "$label_file" 2>/dev/null)"
            else
                label="${chip_name:-hwmon}"
            fi

            # Color-code by severity
            color="$C_GREEN"
            [[ "$temp_c" -gt 60 ]] && color="$C_YELLOW"
            [[ "$temp_c" -gt 80 ]] && color="$C_RED"

            tbl_row "${chip_name:+${chip_name}/}${label}" "${color}${temp_c}°C${C_RESET}"
            found=1
        done
    done
    shopt -u nullglob

    if [[ "$found" -eq 0 ]]; then
        draw_table_end
        draw_box_line "${C_YELLOW}No temperature sensors detected${C_RESET}"
    else
        draw_table_end
    fi

}

# ─────────────────────────────────────────────────────────────────────────────
# BOOT TIMING ANALYSIS (systemd-analyze)
# ─────────────────────────────────────────────────────────────────────────────

scan_boot_timing() {
    draw_section_header "BOOT TIMING (systemd-analyze)"

    if ! command -v systemd-analyze &>/dev/null; then
        draw_box_line "${C_YELLOW}systemd-analyze not available${C_RESET}"
        return 0
    fi

    # Overall boot time
    local boot_time
    boot_time="$(systemd-analyze 2>/dev/null | head -1)" || true

    if [[ -n "$boot_time" ]]; then
        draw_box_line "${C_BOLD}${boot_time}${C_RESET}"
    fi

    printf '\n'

    # Top 10 slowest services
    local blame_output
    blame_output="$(systemd-analyze blame --no-pager 2>/dev/null | head -10)" || true

    if [[ -n "$blame_output" ]]; then
        draw_box_line "${C_BOLD}Top 10 Slowest Services:${C_RESET}"
        printf '%s%*s\n' "$C_CYAN" 64 "" "$C_RESET"

        printf '%s\n' "$blame_output" | while read -r line; do
            [[ -z "$line" ]] && continue

            # Extract service name (last word) and full time string
            local unit="${line##* }"
            local time_str="${line% "$unit"}"
            # Trim leading/trailing spaces with pure bash (zero subprocesses)
            shopt -s extglob
            time_str="${time_str##+([[:space:]])}"
            time_str="${time_str%%+([[:space:]])}"
            shopt -u extglob
            # Extract just the first part for coloring logic (e.g. "3min" from "3min 31s")
            local time_val="${time_str%% *}"
            
            local color="$C_GREEN"

            # Parse time value for coloring (handle "Xs", "Xms", "Xmin")
            local time_sec=0
            if [[ "$time_val" =~ ^([0-9]+)min ]]; then
                time_sec=$((${BASH_REMATCH[1]} * 60))
                # Also add remaining seconds if present (e.g., "3min 31.5s")
                local rest="${time_str#*min }"
                if [[ "$rest" != "$time_str" && "$rest" =~ ^([0-9]+\.?[0-9]*)s ]]; then
                    local extra_sec
                    extra_sec="$(printf '%.0f' "${BASH_REMATCH[1]}" 2>/dev/null)" || extra_sec=0
                    time_sec=$((time_sec + extra_sec))
                fi
            elif [[ "$time_val" =~ ^([0-9]+\.?[0-9]*)s$ ]]; then
                # Round up: 4.999 → 5 for accurate threshold comparison
                time_sec="$(printf '%.0f' "${BASH_REMATCH[1]}" 2>/dev/null)" || time_sec=0
            elif [[ "$time_val" =~ ^([0-9]+)ms$ ]]; then
                time_sec=0
            fi

            [[ "$time_sec" -ge 5 ]] && color="$C_YELLOW"
            [[ "$time_sec" -ge 10 ]] && color="$C_RED"

            draw_box_line "  ${color}${time_str}${C_RESET} ${unit}"
        done
    else
        draw_box_line "${C_YELLOW}⚠ No boot timing data available${C_RESET}"
    fi

}

# ─────────────────────────────────────────────────────────────────────────────
# NETWORK INTERFACE SCANNING (zero-dependency, /sys/class/net)
# ─────────────────────────────────────────────────────────────────────────────

scan_network_interfaces() {
    draw_section_header "NETWORK INTERFACES"
    printf '\n'

    if [[ ! -d /sys/class/net ]]; then
        draw_box_line "${C_YELLOW}/sys/class/net not available${C_RESET}"
        return 0
    fi

    draw_table_begin "Interface" 14 "State" 8 "Speed" 10 "IP" 30

    # Get IP addresses: try ip command, fallback to /proc/net/fib_trie
    declare -A iface_ips
    if command -v ip &>/dev/null; then
        while read -r iface state addr_line; do
            [[ -z "$iface" ]] && continue
            local ip_addr
            # Match IPv4 first, fallback to IPv6 using bash regex (zero subprocesses)
            if [[ "$addr_line" =~ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
                ip_addr="${BASH_REMATCH[1]}"
            elif [[ "$addr_line" =~ ([0-9a-fA-F:]{3,39}(/[0-9]+)?) ]]; then
                ip_addr="${BASH_REMATCH[1]}"
            else
                ip_addr=""
            fi
            [[ -n "$ip_addr" ]] && iface_ips["$iface"]="$ip_addr"
        done < <(ip -br addr 2>/dev/null | grep -v '^lo ')
    fi

    local found=0
    shopt -s nullglob
    for net_path in /sys/class/net/*; do
        [[ ! -d "$net_path" ]] && continue
        local iface
        iface="$(basename "$net_path")"
        [[ "$iface" == "lo" ]] && continue

        # Read operstate
        local state="unknown"
        [[ -f "${net_path}/operstate" ]] && state="$(cat "${net_path}/operstate" 2>/dev/null)"

        # Read speed (may not exist for wireless or down interfaces)
        local speed="N/A"
        if [[ -f "${net_path}/speed" ]]; then
            local raw_speed
            raw_speed="$(cat "${net_path}/speed" 2>/dev/null)" || true
            if [[ -n "$raw_speed" && "$raw_speed" =~ ^[0-9]+$ && "$raw_speed" -gt 0 ]]; then
                if [[ "$raw_speed" -ge 1000 ]]; then
                    speed="$((raw_speed / 1000))Gbps"
                else
                    speed="${raw_speed}Mbps"
                fi
            fi
        fi

        # Get IP from our lookup table
        local ip="${iface_ips[$iface]:-N/A}"

        # Color by state
        local state_color="$C_YELLOW"
        [[ "$state" == "up" ]] && state_color="$C_GREEN"
        [[ "$state" == "down" ]] && state_color="$C_RED"

        tbl_row "$iface" "${state_color}${state}${C_RESET}" "$speed" "$ip"
        found=1
    done
    shopt -u nullglob

    if [[ "$found" -eq 0 ]]; then
        draw_table_end
        draw_box_line "${C_YELLOW}No network interfaces detected (excluding lo)${C_RESET}"
    else
        draw_table_end
    fi

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
            # Resolve symlinks so keys match /proc/mounts
            # Only call readlink -f if path is actually a symlink (avoid fork overhead)
            local resolved_fs
            if [[ -L "$fs" ]]; then
                resolved_fs="$(readlink -f "$fs" 2>/dev/null)" || resolved_fs="$fs"
            else
                resolved_fs="$fs"
            fi
            # Convert KB to human-readable
            if [[ $size -ge 1073741824 ]]; then
                df_sizes["$resolved_fs"]="$((size / 1073741824))T"
            elif [[ $size -ge 1048576 ]]; then
                df_sizes["$resolved_fs"]="$((size / 1048576))G"
            elif [[ $size -ge 1024 ]]; then
                df_sizes["$resolved_fs"]="$((size / 1024))M"
            else
                df_sizes["$resolved_fs"]="${size}K"
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
        
        # Get size from df cache (resolve symlink to match df keys)
        # Only call readlink -f if path is actually a symlink (avoid fork overhead)
        local resolved_source
        if [[ -L "$source" ]]; then
            resolved_source="$(readlink -f "$source" 2>/dev/null)" || resolved_source="$source"
        else
            resolved_source="$source"
        fi
        local size="${df_sizes[$resolved_source]:-${df_sizes[$source]:-N/A}}"
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
        # Validate use_num is numeric before arithmetic comparison
        # df can return "-" for unavailable filesystems (e.g., NFS timeout)
        # Without validation, [[ "-" -gt 90 ]] throws bash arithmetic syntax error
        if [[ "$use_num" =~ ^[0-9]+$ ]]; then
            [[ "$use_num" -gt 90 ]] && color="$C_RED"
            [[ "$use_num" -gt 70 ]] && color="$C_YELLOW"
        fi
        # Non-numeric values (e.g., "-") remain $C_RESET (no color)
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
        return 0
    fi

    # Table header
    draw_table_begin "Vendor" 10 "Product" 30 "Bus/Dev" 8 "Type" 8

    # Use /sys filesystem directly (lightweight, works without lsusb)
    local count=0
    shopt -s nullglob
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

        # Read product ID from sysfs
        local product_id
        product_id="$(cat "$dev_path/idProduct" 2>/dev/null || echo "????")"

        draw_table_row "${vendor}:${product_id}" "${product:0:29}" "Bus ${bus_id}" "$dev_type"
        count=$((count + 1))
    done
    shopt -u nullglob

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

    # Parse all driver fields (16 fields) using IFS - single parse, no subprocesses
    local loaded_count gpu_drv net_drv audio_drv storage_drv usb_drv
    local thunderbolt_drv input_drv platform_drv virtual_drv
    local nvme_drv sata_drv raid_drv i2c_drv smbus_drv watchdog_drv

    IFS='|' read -r loaded_count gpu_drv net_drv audio_drv storage_drv \
        usb_drv thunderbolt_drv input_drv platform_drv virtual_drv \
        nvme_drv sata_drv raid_drv i2c_drv smbus_drv watchdog_drv \
        <<< "$drivers_info"

    # Helper function for status display
    local status_active="${C_GREEN}Active${C_RESET}"
    local status_na="${C_YELLOW}N/A${C_RESET}"

    # Loaded modules count
    draw_box_line "${C_BOLD}Loaded Kernel Modules:${C_RESET} ${C_CYAN}${loaded_count}${C_RESET}"
    printf '\n'

    # Primary drivers table (always shown)
    draw_table_begin "Category" 14 "Driver" 35 "Status" 10
    tbl_row "GPU" "${gpu_drv}" "$([[ "$gpu_drv" != "N/A" ]] && echo "$status_active" || echo "$status_na")"
    tbl_row "Network" "${net_drv}" "$([[ "$net_drv" != "N/A" ]] && echo "$status_active" || echo "$status_na")"
    tbl_row "Audio" "${audio_drv}" "$([[ "$audio_drv" != "N/A" ]] && echo "$status_active" || echo "$status_na")"
    tbl_row "Storage" "${storage_drv}" "$([[ "$storage_drv" != "N/A" ]] && echo "$status_active" || echo "$status_na")"
    tbl_row "USB Controller" "${usb_drv}" "$([[ "$usb_drv" != "N/A" ]] && echo "$status_active" || echo "$status_na")"
    draw_table_end

    printf '\n'

    # Secondary drivers table (shown if any detected)
    local has_secondary=0
    [[ "$thunderbolt_drv" != "N/A" ]] && has_secondary=1
    [[ "$input_drv" != "N/A" ]] && has_secondary=1
    [[ "$platform_drv" != "N/A" ]] && has_secondary=1
    [[ "$virtual_drv" != "N/A" ]] && has_secondary=1
    [[ "$nvme_drv" != "N/A" ]] && has_secondary=1
    [[ "$sata_drv" != "N/A" ]] && has_secondary=1
    [[ "$raid_drv" != "N/A" ]] && has_secondary=1
    [[ "$i2c_drv" != "N/A" ]] && has_secondary=1
    [[ "$smbus_drv" != "N/A" ]] && has_secondary=1
    [[ "$watchdog_drv" != "N/A" ]] && has_secondary=1

    if [[ "$has_secondary" -eq 1 ]]; then
        draw_box_line "${C_BOLD}Additional Drivers:${C_RESET}"
        printf '\n'
        draw_table_begin "Category" 14 "Driver" 35 "Status" 10
        tbl_row "Thunderbolt" "${thunderbolt_drv}" "$([[ "$thunderbolt_drv" != "N/A" ]] && echo "$status_active" || echo "$status_na")"
        tbl_row "Input/HID" "${input_drv}" "$([[ "$input_drv" != "N/A" ]] && echo "$status_active" || echo "$status_na")"
        tbl_row "Platform" "${platform_drv}" "$([[ "$platform_drv" != "N/A" ]] && echo "$status_active" || echo "$status_na")"
        tbl_row "Virtual" "${virtual_drv}" "$([[ "$virtual_drv" != "N/A" ]] && echo "$status_active" || echo "$status_na")"
        tbl_row "NVMe" "${nvme_drv}" "$([[ "$nvme_drv" != "N/A" ]] && echo "$status_active" || echo "$status_na")"
        tbl_row "SATA" "${sata_drv}" "$([[ "$sata_drv" != "N/A" ]] && echo "$status_active" || echo "$status_na")"
        tbl_row "RAID" "${raid_drv}" "$([[ "$raid_drv" != "N/A" ]] && echo "$status_active" || echo "$status_na")"
        tbl_row "I2C" "${i2c_drv}" "$([[ "$i2c_drv" != "N/A" ]] && echo "$status_active" || echo "$status_na")"
        tbl_row "SMBus" "${smbus_drv}" "$([[ "$smbus_drv" != "N/A" ]] && echo "$status_active" || echo "$status_na")"
        tbl_row "Watchdog" "${watchdog_drv}" "$([[ "$watchdog_drv" != "N/A" ]] && echo "$status_active" || echo "$status_na")"
        draw_table_end
        printf '\n'
    fi
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
        read -r ram_total ram_used ram_avail < <(free -h 2>/dev/null | awk '/^Mem:/ {print $2, $3, $7}') || true
        [[ -z "$ram_total" ]] && ram_total="N/A"
        [[ -z "$ram_used" ]]  && ram_used="N/A"
        [[ -z "$ram_avail" ]] && ram_avail="N/A"
        draw_box_line "${C_BOLD}RAM:${C_RESET} Total: ${ram_total} | Used: ${ram_used} | Available: ${ram_avail}"
    fi

    # Swap status from /proc/swaps
    if [[ -f /proc/swaps ]]; then
        local swap_lines
        swap_lines="$(tail -n +2 /proc/swaps 2>/dev/null)"
        if [[ -n "$swap_lines" ]]; then
            draw_box_line "${C_BOLD}Swap:${C_RESET}"
            printf '%s\n' "$swap_lines" | while read -r filename stype size used priority; do
                [[ -z "$filename" ]] && continue
                # Convert KB to human readable
                local size_h used_h
                if [[ "$size" -ge 1048576 ]]; then
                    size_h="$((size / 1048576))G"
                elif [[ "$size" -ge 1024 ]]; then
                    size_h="$((size / 1024))M"
                else
                    size_h="${size}K"
                fi
                if [[ "$used" -ge 1048576 ]]; then
                    used_h="$((used / 1048576))G"
                elif [[ "$used" -ge 1024 ]]; then
                    used_h="$((used / 1024))M"
                else
                    used_h="${used}K"
                fi
                local use_pct=0
                [[ "$size" -gt 0 ]] && use_pct=$((used * 100 / size))
                local color="$C_GREEN"
                [[ "$use_pct" -gt 70 ]] && color="$C_YELLOW"
                [[ "$use_pct" -gt 90 ]] && color="$C_RED"
                draw_box_line "  ${C_CYAN}${filename}${C_RESET} (${stype}) — ${color}${used_h}/${size_h} (${use_pct}%)${C_RESET} pri=${priority}"
            done
            # Check for zram specifically
            shopt -s nullglob
            for zram_dev in /sys/block/zram*; do
                if [[ -f "${zram_dev}/comp_algorithm" && -f "${zram_dev}/disksize" ]]; then
                    local algo disksize_bytes
                    algo="$(cat "${zram_dev}/comp_algorithm" 2>/dev/null | sed 's/.*\[\([^]]*\)\].*/\1/')"
                    disksize_bytes="$(cat "${zram_dev}/disksize" 2>/dev/null)"
                    local disksize_mb=$((disksize_bytes / 1048576))
                    draw_box_line "  ${C_CYAN}$(basename "$zram_dev")${C_RESET} algorithm: ${algo} | capacity: ${disksize_mb}M"
                fi
            done
            shopt -u nullglob
        else
            draw_box_line "${C_YELLOW}Swap: Not configured${C_RESET}"
        fi
    else
        draw_box_line "${C_YELLOW}Swap: /proc/swaps not available${C_RESET}"
    fi

    # Disk
    local disk_total disk_used disk_avail
    if command -v df &>/dev/null; then
        local root_info
        root_info="$(df -h / 2>/dev/null | tail -1)"
        # Extract fields with pure bash (zero subprocesses)
        # df output: Filesystem Size Used Avail Use% Mounted
        # Fields:    $1        $2   $3   $4    $5   $6
        read -r _ disk_total disk_used disk_avail _ _ <<< "$root_info"
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

    # Resolve symlinks to get real path (important for cross-filesystem symlinks)
    local resolved
    resolved="$(readlink -f "$target_dir" 2>/dev/null)" || resolved="$target_dir"

    # If resolved target doesn't exist, check parent directory
    if [[ ! -e "$resolved" ]]; then
        check_path="$(dirname "$resolved")"
        # If parent doesn't exist either, check root
        [[ ! -d "$check_path" ]] && check_path="/"
    elif [[ -f "$resolved" ]]; then
        # Get parent directory if target is a file
        check_path="$(dirname "$resolved")"
    else
        check_path="$resolved"
    fi

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
    local new_output_dir="./arch-diag-logs/${timestamp}"

    # Check disk space before mutating global state
    if ! check_disk_space "$new_output_dir"; then
        warn "Insufficient disk space for export"
        return 1
    fi

    if ! mkdir -p "$new_output_dir" 2>/dev/null; then
        warn "Could not create output directory: $new_output_dir"
        return 1
    fi

    # All checks passed — assign to global
    OUTPUT_DIR="$new_output_dir"
    info "Logs will be saved to: $OUTPUT_DIR"
    return 0
}

export_kernel_logs() {
    local -a boot_args=(-b "$BOOT_OFFSET")
    
    # Guard: validate OUTPUT_DIR
    if [[ -z "$OUTPUT_DIR" || ! -d "$OUTPUT_DIR" ]]; then
        warn "export_kernel_logs: OUTPUT_DIR not set or invalid"
        return 1
    fi
    
    local output_file="${OUTPUT_DIR}/kernel_errors.txt"
    local journal_output

    journal_output="$(timeout 10 journalctl -k -p 3 "${boot_args[@]}" --no-pager 2>/dev/null)" || true

    if [[ -z "$journal_output" ]]; then
        printf 'No kernel errors found for boot: %s\n' "${boot_args[*]}" > "$output_file"
        return 0
    fi

    # Write raw log
    printf '%s\n' "$journal_output" > "$output_file"

    # Write clustered version
    local clustered_file="${OUTPUT_DIR}/kernel_errors_clustered.txt"
    printf '%s\n' "$journal_output" | \
        sed -E 's/^[A-Za-z]{3} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [^ ]+ //' | \
        sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:?[0-9]{2} [^ ]+ //' | \
        sort | uniq -c | sort -rn > "$clustered_file"

    info "Kernel logs exported: kernel_errors.txt, kernel_errors_clustered.txt"
}

export_user_services() {
    local -a boot_args=(-b "$BOOT_OFFSET")
    
    # Guard: validate OUTPUT_DIR
    if [[ -z "$OUTPUT_DIR" || ! -d "$OUTPUT_DIR" ]]; then
        warn "export_user_services: OUTPUT_DIR not set or invalid"
        return 1
    fi
    
    local output_file="${OUTPUT_DIR}/service_errors.txt"
    local journal_output

    journal_output="$(timeout 10 journalctl -u "*.service" -p 3 "${boot_args[@]}" --no-pager 2>/dev/null)" || true

    if [[ -z "$journal_output" ]]; then
        printf 'No service errors found for boot: %s\n' "${boot_args[*]}" > "$output_file"
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
            timeout 15 lsusb -v 2>/dev/null | head -100 || true
        else
            printf 'lsusb not available\n'
        fi

        printf '\n=============================================================\n'
        printf 'USB STORAGE (lsblk)\n'
        printf '=============================================================\n\n'

        if command -v lsblk &>/dev/null; then
            # Match removable devices (sd*, mmcblk*) - USB storage indicator
            lsblk -dnbo NAME,MODEL,SIZE,VENDOR,MOUNTPOINT 2>/dev/null | grep -E '^sd|^mmcblk' || true
        fi
    } > "$output_file"

    info "USB devices exported: usb_devices.txt"
}

export_temperatures() {
    # Guard: validate OUTPUT_DIR
    if [[ -z "$OUTPUT_DIR" || ! -d "$OUTPUT_DIR" ]]; then
        warn "export_temperatures: OUTPUT_DIR not set or invalid"
        return 1
    fi

    local output_file="${OUTPUT_DIR}/temperatures.txt"

    {
        printf '=============================================================\n'
        printf 'HARDWARE TEMPERATURES\n'
        printf '=============================================================\n\n'

        if [[ -d /sys/class/hwmon ]]; then
            printf '%-30s %s\n' 'Sensor' 'Temperature'
            printf '%-30s %s\n' '──────────────' '───────────'
            shopt -s nullglob
            for hw_dir in /sys/class/hwmon/hwmon*; do
                [[ ! -d "$hw_dir" ]] && continue
                local hw_name=""
                [[ -f "${hw_dir}/name" ]] && hw_name="$(cat "${hw_dir}/name" 2>/dev/null)"
                for ti in "${hw_dir}"/temp*_input; do
                    [[ ! -f "$ti" ]] && continue
                    local tr_val
                    tr_val="$(cat "$ti" 2>/dev/null)" || continue
                    [[ -z "$tr_val" || ! "$tr_val" =~ ^-?[0-9]+$ ]] && continue
                    local lbl_file="${ti%_input}_label"
                    local lbl="${hw_name:-hwmon}"
                    [[ -f "$lbl_file" ]] && lbl="$(cat "$lbl_file" 2>/dev/null)"
                    printf '%-30s %d°C\n' "${hw_name:-hwmon}/${lbl}" $((tr_val / 1000))
                done
            done
            shopt -u nullglob
        else
            printf 'hwmon not available.\n'
        fi
    } > "$output_file"

    info "Temperatures exported: temperatures.txt"
}

export_boot_timing() {
    # Guard: validate OUTPUT_DIR
    if [[ -z "$OUTPUT_DIR" || ! -d "$OUTPUT_DIR" ]]; then
        warn "export_boot_timing: OUTPUT_DIR not set or invalid"
        return 1
    fi

    local output_file="${OUTPUT_DIR}/boot_timing.txt"

    {
        printf '=============================================================\n'
        printf 'BOOT TIMING (systemd-analyze)\n'
        printf '=============================================================\n\n'

        if command -v systemd-analyze &>/dev/null; then
            systemd-analyze 2>/dev/null | head -1 || true
            printf '\nTop 20 slowest services:\n'
            systemd-analyze blame --no-pager 2>/dev/null | head -20 || true
        else
            printf 'systemd-analyze not available.\n'
        fi
    } > "$output_file"

    info "Boot timing exported: boot_timing.txt"
}

export_network_interfaces() {
    # Guard: validate OUTPUT_DIR
    if [[ -z "$OUTPUT_DIR" || ! -d "$OUTPUT_DIR" ]]; then
        warn "export_network_interfaces: OUTPUT_DIR not set or invalid"
        return 1
    fi

    local output_file="${OUTPUT_DIR}/network_interfaces.txt"

    {
        printf '=============================================================\n'
        printf 'NETWORK INTERFACES\n'
        printf '=============================================================\n\n'

        if [[ -d /sys/class/net ]]; then
            printf '%-16s %-8s %-10s %-20s %s\n' 'Interface' 'State' 'Speed' 'MAC' 'IP'
            printf '%-16s %-8s %-10s %-20s %s\n' '─────────' '─────' '─────' '───' '──'
            for net_path in /sys/class/net/*; do
                [[ ! -d "$net_path" ]] && continue
                local iface_name
                iface_name="$(basename "$net_path")"
                [[ "$iface_name" == "lo" ]] && continue
                local e_state="unknown" e_speed="N/A" e_mac="N/A"
                [[ -f "${net_path}/operstate" ]] && e_state="$(cat "${net_path}/operstate" 2>/dev/null)"
                if [[ -f "${net_path}/speed" ]]; then
                    local rs
                    rs="$(cat "${net_path}/speed" 2>/dev/null)" || true
                    if [[ -n "$rs" && "$rs" =~ ^[0-9]+$ && "$rs" -gt 0 ]]; then
                        if [[ "$rs" -ge 1000 ]]; then
                            e_speed="$((rs / 1000))Gbps"
                        else
                            e_speed="${rs}Mbps"
                        fi
                    fi
                fi
                [[ -f "${net_path}/address" ]] && e_mac="$(cat "${net_path}/address" 2>/dev/null)"
                local e_ip="N/A"
                if command -v ip &>/dev/null; then
                    e_ip="$(ip -br addr show dev "$iface_name" 2>/dev/null | awk '{print $3}' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
                    if [[ -z "$e_ip" ]]; then
                        e_ip="$(ip -br addr show dev "$iface_name" 2>/dev/null | awk '{print $3}' | grep -oE '[0-9a-fA-F:]{3,39}(/[0-9]+)?' | head -1)"
                    fi
                    [[ -z "$e_ip" ]] && e_ip="N/A"
                fi
                printf '%-16s %-8s %-10s %-20s %s\n' "$iface_name" "$e_state" "$e_speed" "$e_mac" "$e_ip"
            done
        else
            printf '/sys/class/net not available.\n'
        fi
    } > "$output_file"

    info "Network interfaces exported: network_interfaces.txt"
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
        printf 'DRIVER STATUS - COMPREHENSIVE REPORT\n'
        printf '=============================================================\n'
        printf 'Generated: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf '=============================================================\n\n'

        # Section 1: Kernel modules
        printf '=============================================================\n'
        printf '[1] LOADED KERNEL MODULES\n'
        printf '=============================================================\n\n'
        lsmod 2>/dev/null || printf 'Unable to list kernel modules\n'
        printf '\n\n'

        # Section 2: PCI devices with drivers
        printf '=============================================================\n'
        printf '[2] PCI DEVICES WITH DRIVERS\n'
        printf '=============================================================\n\n'
        _get_lspci_knn
        if [[ -n "$_LSPCI_KNN_CACHE" ]]; then
            printf '%s\n' "$_LSPCI_KNN_CACHE"
        else
            printf 'lspci not available\n'
        fi
        printf '\n\n'

        # Section 3: USB devices
        printf '=============================================================\n'
        printf '[3] USB DEVICES\n'
        printf '=============================================================\n\n'
        if command -v lsusb &>/dev/null; then
            timeout 15 lsusb -v 2>/dev/null | head -200 || timeout 5 lsusb 2>/dev/null || true
        else
            printf 'lsusb not available\n'
        fi
        printf '\n\n'

        # Section 4: DRM/GPU drivers
        printf '=============================================================\n'
        printf '[4] GPU/DRM DRIVERS\n'
        printf '=============================================================\n\n'
        if [[ -d /sys/class/drm ]]; then
            shopt -s nullglob
            for card in /sys/class/drm/card*; do
                [[ ! -d "$card" ]] && continue
                printf 'Device: %s\n' "$(basename "$card")"
                if [[ -L "${card}/device/driver" ]]; then
                    printf 'Driver: %s\n' "$(readlink "${card}/device/driver" 2>/dev/null | xargs -r basename 2>/dev/null)"
                fi
                printf '\n'
            done
            shopt -u nullglob
        else
            printf 'DRM subsystem not available\n'
        fi
        printf '\n'

        # Section 5: Network drivers
        printf '=============================================================\n'
        printf '[5] NETWORK DRIVERS\n'
        printf '=============================================================\n\n'
        if [[ -d /sys/class/net ]]; then
            shopt -s nullglob
            for iface in /sys/class/net/*; do
                [[ ! -d "$iface" ]] && continue
                local iface_name
                iface_name="$(basename "$iface")"
                printf 'Interface: %s\n' "$iface_name"
                if [[ -L "${iface}/device/driver" ]]; then
                    printf 'Driver: %s\n' "$(readlink "${iface}/device/driver" 2>/dev/null | xargs -r basename 2>/dev/null)"
                fi
                printf '\n'
            done
            shopt -u nullglob
        else
            printf 'Network subsystem not available\n'
        fi
        printf '\n'

        # Section 6: Audio drivers
        printf '=============================================================\n'
        printf '[6] AUDIO DRIVERS\n'
        printf '=============================================================\n\n'
        if [[ -d /sys/class/sound ]]; then
            shopt -s nullglob
            for sound in /sys/class/sound/*; do
                [[ ! -d "$sound" ]] && continue
                printf 'Device: %s\n' "$(basename "$sound")"
                if [[ -L "${sound}/device/driver" ]]; then
                    printf 'Driver: %s\n' "$(readlink "${sound}/device/driver" 2>/dev/null | xargs -r basename 2>/dev/null)"
                fi
                printf '\n'
            done
            shopt -u nullglob
        else
            printf 'Sound subsystem not available\n'
        fi
        printf '\n'

        # Section 7: Storage drivers
        printf '=============================================================\n'
        printf '[7] STORAGE DRIVERS\n'
        printf '=============================================================\n\n'
        if [[ -d /sys/block ]]; then
            shopt -s nullglob
            for block in /sys/block/*; do
                [[ ! -d "$block" ]] && continue
                local bname
                bname="$(basename "$block")"
                printf 'Device: %s\n' "$bname"
                if [[ -L "${block}/device/driver" ]]; then
                    printf 'Driver: %s\n' "$(readlink "${block}/device/driver" 2>/dev/null | xargs -r basename 2>/dev/null)"
                fi
                printf '\n'
            done
            shopt -u nullglob
        else
            printf 'Block subsystem not available\n'
        fi
        printf '\n'

        # Section 8: Input drivers
        printf '=============================================================\n'
        printf '[8] INPUT/HID DRIVERS\n'
        printf '=============================================================\n\n'
        if [[ -d /sys/class/input ]]; then
            shopt -s nullglob
            for input in /sys/class/input/*; do
                [[ ! -d "$input" ]] && continue
                printf 'Device: %s\n' "$(basename "$input")"
                if [[ -L "${input}/device/driver" ]]; then
                    printf 'Driver: %s\n' "$(readlink "${input}/device/driver" 2>/dev/null | xargs -r basename 2>/dev/null)"
                fi
                printf '\n'
            done
            shopt -u nullglob
        else
            printf 'Input subsystem not available\n'
        fi
        printf '\n'

        # Section 9: Platform drivers
        printf '=============================================================\n'
        printf '[9] PLATFORM DRIVERS\n'
        printf '=============================================================\n\n'
        if [[ -d /sys/bus/platform/drivers ]]; then
            ls -1 /sys/bus/platform/drivers/ 2>/dev/null | head -50 || printf 'Unable to list platform drivers\n'
        else
            printf 'Platform bus not available\n'
        fi
        printf '\n'

        # Section 10: Virtual drivers
        printf '=============================================================\n'
        printf '[10] VIRTUAL/HYPERVISOR DRIVERS\n'
        printf '=============================================================\n\n'
        if [[ -d /sys/bus/pci/drivers ]]; then
            printf 'PCI Drivers indicating virtualization:\n'
            ls -1 /sys/bus/pci/drivers/ 2>/dev/null | grep -iE 'virtio|vmware|vbox|xen|qxl' || printf 'No virtual drivers detected\n'
        else
            printf 'PCI bus not available\n'
        fi
        printf '\n'

        printf '=============================================================\n'
        printf 'END OF DRIVER REPORT\n'
        printf '=============================================================\n'

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
    local -a boot_args=(-b "$BOOT_OFFSET")
    
    # Guard: validate OUTPUT_DIR
    if [[ -z "$OUTPUT_DIR" || ! -d "$OUTPUT_DIR" ]]; then
        warn "export_all_logs: OUTPUT_DIR not set or invalid"
        return 1
    fi
    
    local output_file="${OUTPUT_DIR}/arch-log-inspector-all.txt"
    local temp_file
    temp_file="$(mktemp)"

    # Cleanup trap: use EXIT instead of RETURN
    # EXIT fires on set -e termination, signal, or normal exit
    # RETURN only fires on normal function return (not sufficient)
    trap 'rm -f "$temp_file" 2>/dev/null || true' EXIT

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
        kernel_output="$(timeout 10 journalctl -k -p 3 "${boot_args[@]}" --no-pager 2>/dev/null)" || true
        if [[ -n "$kernel_output" ]]; then
            printf '%s\n' "$kernel_output"
        else
            printf 'No kernel errors found.\n'
        fi
        printf '\n\n'

        # ─────────────────────────────────────────────────────────────────────
        # BOOT TIMING
        # ─────────────────────────────────────────────────────────────────────
        printf '=============================================================\n'
        printf '[2] BOOT TIMING (systemd-analyze)\n'
        printf '=============================================================\n'
        if command -v systemd-analyze &>/dev/null; then
            systemd-analyze 2>/dev/null | head -1 || true
            printf '\nTop 15 slowest services:\n'
            systemd-analyze blame --no-pager 2>/dev/null | head -15 || true
        else
            printf 'systemd-analyze not available.\n'
        fi
        printf '\n\n'
        # ─────────────────────────────────────────────────────────────────────
        # USER SERVICES
        # ─────────────────────────────────────────────────────────────────────
        printf '=============================================================\n'
        printf '[3] USER SERVICES\n'
        printf '=============================================================\n'
        local service_output
        service_output="$(timeout 10 journalctl -u "*.service" -p 3 "${boot_args[@]}" --no-pager 2>/dev/null)" || true
        if [[ -n "$service_output" ]]; then
            printf '%s\n' "$service_output"
        else
            printf 'No service errors found.\n'
        fi
        printf '\n\n'

        # ─────────────────────────────────────────────────────────────────────
        # FAILED SERVICES (systemctl --failed)
        # ─────────────────────────────────────────────────────────────────────
        printf '=============================================================\n'
        printf '[4] FAILED SERVICES (systemctl --failed)\n'
        printf '=============================================================\n'
        if command -v systemctl &>/dev/null; then
            local failed_svc
            failed_svc="$(systemctl --failed --no-pager 2>/dev/null)" || true
            if [[ -n "$failed_svc" ]]; then
                printf '%s\n' "$failed_svc"
            else
                printf 'No failed services.\n'
            fi
        else
            printf 'systemctl not available.\n'
        fi
        printf '\n\n'

        # ─────────────────────────────────────────────────────────────────────
        # CORE DUMPS
        # ─────────────────────────────────────────────────────────────────────
        printf '=============================================================\n'
        printf '[5] CORE DUMPS\n'
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
        printf '[6] PACMAN LOGS (Errors & Warnings)\n'
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
        printf '[7] MOUNTED FILESYSTEMS\n'
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
        printf '[8] DISK USAGE\n'
        printf '=============================================================\n'
        df -h 2>/dev/null || true
        printf '\n\n'

        # ─────────────────────────────────────────────────────────────────────
        # USB DEVICES
        # ─────────────────────────────────────────────────────────────────────
        printf '=============================================================\n'
        printf '[9] USB DEVICES\n'
        printf '=============================================================\n'
        if command -v lsusb &>/dev/null; then
            timeout 15 lsusb -v 2>/dev/null | head -100 || true
        else
            printf 'lsusb not available.\n'
        fi
        printf '\n\n'

        # ─────────────────────────────────────────────────────────────────────
        # NETWORK INTERFACES
        # ─────────────────────────────────────────────────────────────────────
        printf '=============================================================\n'
        printf '[10] NETWORK INTERFACES\n'
        printf '=============================================================\n'
        if [[ -d /sys/class/net ]]; then
            printf '%-16s %-8s %-10s %-20s %s\n' 'Interface' 'State' 'Speed' 'MAC' 'IP'
            printf '%-16s %-8s %-10s %-20s %s\n' '─────────' '─────' '─────' '───' '──'
            for net_path in /sys/class/net/*; do
                [[ ! -d "$net_path" ]] && continue
                local iface_name
                iface_name="$(basename "$net_path")"
                [[ "$iface_name" == "lo" ]] && continue
                local e_state="unknown" e_speed="N/A" e_mac="N/A"
                [[ -f "${net_path}/operstate" ]] && e_state="$(cat "${net_path}/operstate" 2>/dev/null)"
                if [[ -f "${net_path}/speed" ]]; then
                    local rs
                    rs="$(cat "${net_path}/speed" 2>/dev/null)" || true
                    if [[ -n "$rs" && "$rs" =~ ^[0-9]+$ && "$rs" -gt 0 ]]; then
                        if [[ "$rs" -ge 1000 ]]; then
                            e_speed="$((rs / 1000))Gbps"
                        else
                            e_speed="${rs}Mbps"
                        fi
                    fi
                fi
                [[ -f "${net_path}/address" ]] && e_mac="$(cat "${net_path}/address" 2>/dev/null)"
                local e_ip="N/A"
                if command -v ip &>/dev/null; then
                    e_ip="$(ip -br addr show dev "$iface_name" 2>/dev/null | awk '{print $3}' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
                    if [[ -z "$e_ip" ]]; then
                        e_ip="$(ip -br addr show dev "$iface_name" 2>/dev/null | awk '{print $3}' | grep -oE '[0-9a-fA-F:]{3,39}(/[0-9]+)?' | head -1)"
                    fi
                    [[ -z "$e_ip" ]] && e_ip="N/A"
                fi
                printf '%-16s %-8s %-10s %-20s %s\n' "$iface_name" "$e_state" "$e_speed" "$e_mac" "$e_ip"
            done
        else
            printf '/sys/class/net not available.\n'
        fi
        printf '\n\n'
        # ─────────────────────────────────────────────────────────────────────
        printf '=============================================================\n'
        printf '[11] GPU / VGA INFO\n'
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
        printf '[12] DRIVER STATUS\n'
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
        printf '[13] SYSTEM INFO\n'
        printf '=============================================================\n'
        printf 'Internet: %s\n' "$INTERNET_STATUS"
        printf 'CPU: %s\n' "$(grep 'model name' /proc/cpuinfo 2>/dev/null | head -1 | cut -d':' -f2 | sed 's/^ *//' || echo 'Unknown')"
        printf 'CPU Cores: %s\n' "$(nproc 2>/dev/null || echo '?')"
        printf 'Memory:\n'
        free -h 2>/dev/null || true
        printf '\nSwap:\n'
        if [[ -f /proc/swaps ]]; then
            cat /proc/swaps 2>/dev/null || true
        else
            printf '/proc/swaps not available.\n'
        fi
        printf '\nUptime: %s\n' "$(uptime -p 2>/dev/null || uptime | sed 's/.*up /up /' | cut -d',' -f1-2)"
        printf '\n'

        # Hardware temperatures
        printf 'Temperatures:\n'
        if [[ -d /sys/class/hwmon ]]; then
            shopt -s nullglob
            local temp_found=0
            for hw_dir in /sys/class/hwmon/hwmon*; do
                [[ ! -d "$hw_dir" ]] && continue
                local hw_name=""
                [[ -f "${hw_dir}/name" ]] && hw_name="$(cat "${hw_dir}/name" 2>/dev/null)"
                for ti in "${hw_dir}"/temp*_input; do
                    [[ ! -f "$ti" ]] && continue
                    local tr_val
                    tr_val="$(cat "$ti" 2>/dev/null)" || continue
                    [[ -z "$tr_val" || ! "$tr_val" =~ ^-?[0-9]+$ ]] && continue
                    local lbl_file="${ti%_input}_label"
                    local lbl="${hw_name:-hwmon}"
                    [[ -f "$lbl_file" ]] && lbl="$(cat "$lbl_file" 2>/dev/null)"
                    printf '  %s/%s: %d°C\n' "${hw_name:-hwmon}" "$lbl" $((tr_val / 1000))
                    temp_found=1
                done
            done
            shopt -u nullglob
            [[ "$temp_found" -eq 0 ]] && printf '  No temperature sensors detected.\n'
        else
            printf '  hwmon not available.\n'
        fi
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
    trap - EXIT

    info "All logs exported to: ${output_file}"
}

# ─────────────────────────────────────────────────────────────────────────────
# CLI ARGUMENT PARSER (MANUAL - NO GETOPT)
# ─────────────────────────────────────────────────────────────────────────────

parse_args() {
    while [[ $# -gt 0 ]]; do
        local arg="$1"
        case "$arg" in
            --all)
                SCAN_ALL=1
                SCAN_KERNEL=0
                SCAN_USER=0
                SCAN_MOUNT=0
                SCAN_USB=0
                shift
                ;;
            --kernel)
                SCAN_ALL=0
                SCAN_KERNEL=1
                shift
                ;;
            --user)
                SCAN_ALL=0
                SCAN_USER=1
                shift
                ;;
            --mount)
                SCAN_ALL=0
                SCAN_MOUNT=1
                shift
                ;;
            --usb)
                SCAN_ALL=0
                SCAN_USB=1
                shift
                ;;
            --driver)
                SCAN_ALL=0
                SCAN_DRIVER=1
                shift
                ;;
            --vga)
                SCAN_ALL=0
                SCAN_VGA=1
                shift
                ;;
            --system)
                SCAN_ALL=0
                SCAN_SYSTEM=1
                shift
                ;;
            --wiki)
                SCAN_ALL=0
                SCAN_WIKI=1
                # Check if next argument is a group name (doesn't start with -)
                if [[ $# -gt 1 && ! "$2" =~ ^- ]]; then
                    WIKI_GROUP="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            --wiki=*)
                SCAN_ALL=0
                SCAN_WIKI=1
                WIKI_GROUP="${arg#--wiki=}"
                shift
                ;;
            --wiki-group=*)
                SCAN_ALL=0
                SCAN_WIKI=1
                WIKI_GROUP="${arg#--wiki-group=}"
                shift
                ;;
            --boot=*)
                BOOT_OFFSET="${arg#--boot=}"
                # Validate numeric
                if ! [[ "$BOOT_OFFSET" =~ ^-?[0-9]+$ ]]; then
                    die "Invalid boot offset: $BOOT_OFFSET (must be integer)"
                fi
                # Validate reasonable range (systemd typically keeps 10-20 boots)
                # Reject extreme values that would cause confusing journalctl errors
                if [[ "$BOOT_OFFSET" -lt -100 || "$BOOT_OFFSET" -gt 100 ]]; then
                    die "Boot offset out of range: $BOOT_OFFSET (must be between -100 and 100)"
                fi
                shift
                ;;
            --save)
                SAVE_LOGS=1
                shift
                ;;
            --save-all)
                SAVE_ALL=1
                shift
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

# Alias mapping for common shorthand/alternative names
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

# AWK-based fuzzy matching - optimized for speed
# Uses Levenshtein distance with awk
awk_fuzzy_match() {
    local query="$1"
    local groups="$2"
    
    # Use awk for fast string processing
    echo "$groups" | awk -v q="$query" '
    BEGIN {
        best_idx = -1
        best_dist = 999
    }
    
    function min3(a, b, c) {
        return (a < b) ? ((a < c) ? a : c) : ((b < c) ? b : c)
    }
    
    function levenshtein(s1, s2,    len1, len2, i, j, d, c1, c2, cost, tmp) {
        len1 = length(s1)
        len2 = length(s2)
        if (len1 == 0) return len2
        if (len2 == 0) return len1
        if (len1 > len2) { tmp = s1; s1 = s2; s2 = tmp; tmp = len1; len1 = len2; len2 = tmp }
        
        # Clear array to prevent memory accumulation
        split("", d)
        
        for (j = 0; j <= len2; j++) d[0, j] = j
        for (i = 1; i <= len1; i++) {
            d[i, 0] = i
            c1 = substr(s1, i, 1)
            for (j = 1; j <= len2; j++) {
                c2 = substr(s2, j, 1)
                cost = (c1 == c2) ? 0 : 1
                d[i, j] = min3(d[i-1, j] + 1, d[i, j-1] + 1, d[i-1, j-1] + cost)
            }
        }
        return d[len1, len2]
    }
    
    function get_threshold(len) {
        if (len <= 4) return 1
        if (len <= 8) return 2
        return 3
    }
    
    {
        idx = NR - 1
        split($0, parts, " ")
        keyword = parts[1]
        
        dist = levenshtein(q, keyword)
        threshold = get_threshold(length(keyword))
        
        if (dist <= threshold && dist < best_dist) {
            best_dist = dist
            best_idx = idx
            if (dist == 0) exit
        }
    }
    
    END {
        print best_idx ":" best_dist
    }
    '
}

# Find best match using awk fuzzy matching
find_wiki_group_awk() {
    local query="$1"

    # Normalize query: lowercase, trim whitespace, remove special chars (security)
    query="$(echo "$query" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -cd '[:alnum:]_ -')"

    # Early exit for empty or invalid query
    if [[ -z "$query" || ${#query} -gt 50 ]]; then
        echo "-1"
        return 1
    fi

    # FAST PATH 1: Alias lookup
    if [[ -n "${WIKI_ALIASES[$query]:-}" ]]; then
        local target="${WIKI_ALIASES[$query]}"
        local i=0
        for group in "${WIKI_GROUP_NAMES[@]}"; do
            [[ "$group" == *"$target"* ]] && echo $i && return 0
            i=$((i+1))
        done
    fi
    
    # FAST PATH 2: Exact match
    local i=0
    for group in "${WIKI_GROUP_NAMES[@]}"; do
        [[ "$group" == *"$query"* ]] && echo $i && return 0
        i=$((i+1))
    done
    
    # AWK PATH: Fuzzy matching
    local groups_str
    groups_str="$(printf '%s\n' "${WIKI_GROUP_NAMES[@]}")"
    local result
    result="$(awk_fuzzy_match "$query" "$groups_str")"
    
    local best_idx="${result%%:*}"
    local best_dist="${result##*:}"
    
    if [[ "$best_idx" -ge 0 && "$best_dist" -le 3 ]]; then
        echo "$best_idx" && return 0
    fi
    
    echo "-1"
    return 1
}

# Get suggestions using awk
suggest_wiki_groups_awk() {
    local query="$1"

    # Normalize: lowercase, trim, remove special chars (security)
    query="$(echo "$query" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -cd '[:alnum:]_ -')"

    # Early exit for empty or too long query (DoS prevention)
    if [[ -z "$query" || ${#query} -gt 50 ]]; then
        return 1
    fi

    local groups_str
    groups_str="$(printf '%s\n' "${WIKI_GROUP_NAMES[@]}")"
    
    echo "$groups_str" | awk -v q="$query" '
    function min3(a, b, c) { return (a < b) ? ((a < c) ? a : c) : ((b < c) ? b : c) }
    
    function levenshtein(s1, s2,    len1, len2, i, j, d, c1, c2, cost, tmp) {
        len1 = length(s1); len2 = length(s2)
        if (len1 == 0) return len2
        if (len2 == 0) return len1
        if (len1 > len2) { tmp = s1; s1 = s2; s2 = tmp; tmp = len1; len1 = len2; len2 = tmp }
        # Clear array to prevent memory accumulation
        split("", d)
        for (j = 0; j <= len2; j++) d[0, j] = j
        for (i = 1; i <= len1; i++) {
            d[i, 0] = i; c1 = substr(s1, i, 1)
            for (j = 1; j <= len2; j++) {
                c2 = substr(s2, j, 1); cost = (c1 == c2) ? 0 : 1
                d[i, j] = min3(d[i-1, j] + 1, d[i, j-1] + 1, d[i-1, j-1] + cost)
            }
        }
        return d[len1, len2]
    }

    # Threshold: max allowed Levenshtein distance based on word length
    # len<=4: max 1 typo (e.g., "soud" → "sound")
    # len<=8: max 2 typos (e.g., "netwok" → "network")
    # len>8:  max 3 typos for long words
    function get_threshold(len) { if (len <= 4) return 1; if (len <= 8) return 2; return 3 }
    
    {
        idx = NR - 1
        split($0, parts, " ")
        keyword = parts[1]
        dist = levenshtein(q, keyword)
        threshold = get_threshold(length(keyword))
        if (dist <= threshold) {
            suggestions[++count] = $0
            distances[count] = dist
        }
    }
    
    END {
        # Simple bubble sort by distance
        for (i = 1; i < count; i++) {
            for (j = i + 1; j <= count; j++) {
                if (distances[j] < distances[i]) {
                    tmp = suggestions[i]; suggestions[i] = suggestions[j]; suggestions[j] = tmp
                    tmp = distances[i]; distances[i] = distances[j]; distances[j] = tmp
                }
            }
        }
        # Print top 3
        for (i = 1; i <= 3 && i <= count; i++) print suggestions[i]
    }
    '
}

# Find group index using awk fuzzy matching (optimized)
find_wiki_group() {
    find_wiki_group_awk "$1"
}

# Get suggestions using awk (optimized)
suggest_wiki_groups() {
    suggest_wiki_groups_awk "$1"
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
                # Parse dynamic suggestions from awk output
                printf '%s\n' "$suggestions" | while read -r sug_line; do
                    local cmd desc
                    # First word is the keyword, the rest is description/aliases
                    cmd="$(echo "$sug_line" | awk '{print $1}')"
                    # We map back into our descriptive format. $sug_line contains the raw WIKI_GROUP_NAMES text
                    # We use cut to skip the first word if needed, or just display the whole match as hint
                    desc="$(echo "$sug_line" | cut -d' ' -f2-)"
                    draw_box_line "  ${C_CYAN}--wiki ${cmd}${C_RESET} - Matches: ${desc}"
                done
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
    init_colors
    parse_args "$@"

    # Wiki mode: skip all system detection, just show wiki and exit
    if [[ "$SCAN_WIKI" -eq 1 ]]; then
        show_wiki
        return 0
    fi

    detect_distro
    detect_system_info
    check_internet || true
    detect_gpu
    detect_display

    local width=70

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
        scan_temperatures
        scan_vga_info
        scan_drivers
        scan_kernel_logs
        scan_boot_timing
        scan_user_services
        scan_coredumps
        scan_pacman_logs
        scan_mounts
        scan_usb_devices
        scan_network_interfaces

        # Export logs if --save is set (separate files)
        if [[ "$SAVE_LOGS" -eq 1 ]]; then
            printf '\n'
            draw_box_line "${C_CYAN}Exporting logs to ${OUTPUT_DIR}...${C_RESET}"
            
            local export_failed=0
            
            export_kernel_logs || { warn "Export kernel logs failed"; export_failed=1; }
            export_user_services || { warn "Export user services failed"; export_failed=1; }
            export_coredumps || { warn "Export coredumps failed"; export_failed=1; }
            export_pacman_logs || { warn "Export pacman logs failed"; export_failed=1; }
            export_mounts || { warn "Export mounts failed"; export_failed=1; }
            export_usb_devices || { warn "Export USB devices failed"; export_failed=1; }
            export_vga_info || { warn "Export VGA info failed"; export_failed=1; }
            export_drivers || { warn "Export drivers failed"; export_failed=1; }
            export_temperatures || { warn "Export temperatures failed"; export_failed=1; }
            export_boot_timing || { warn "Export boot timing failed"; export_failed=1; }
            export_network_interfaces || { warn "Export network interfaces failed"; export_failed=1; }
            export_summary || { warn "Export summary failed"; export_failed=1; }
            
            if [[ "$export_failed" -eq 1 ]]; then
                draw_box_line "${C_YELLOW}⚠ Some exports failed (check warnings above)${C_RESET}"
            else
                draw_box_line "${C_GREEN}✓ Export complete: ${OUTPUT_DIR}${C_RESET}"
            fi
        # Export all logs if --save-all is set (single file)
        elif [[ "$SAVE_ALL" -eq 1 ]]; then
            printf '\n'
            draw_box_line "${C_CYAN}Exporting all logs to single file...${C_RESET}"
            if export_all_logs; then
                draw_box_line "${C_GREEN}✓ Export complete: ${OUTPUT_DIR}/arch-log-inspector-all.txt${C_RESET}"
            else
                draw_box_line "${C_RED}✗ Export failed (check warnings above)${C_RESET}"
            fi
        fi

        # Clear individual flags to prevent double execution in independent blocks
        SCAN_DRIVER=0 SCAN_VGA=0 SCAN_KERNEL=0 SCAN_USER=0 SCAN_MOUNT=0 SCAN_USB=0

    elif [[ "$SCAN_SYSTEM" -eq 1 ]]; then
        # --system flag: full system scan without logs
        scan_system_basics
        scan_temperatures
        scan_vga_info
        scan_drivers
        scan_boot_timing
        scan_mounts
        scan_usb_devices
        scan_network_interfaces

        if [[ "$SAVE_LOGS" -eq 1 ]]; then
            printf '\n'
            draw_box_line "${C_CYAN}Exporting logs to ${OUTPUT_DIR}...${C_RESET}"
            
            local export_failed=0
            export_mounts || { warn "Export mounts failed"; export_failed=1; }
            export_usb_devices || { warn "Export USB devices failed"; export_failed=1; }
            export_vga_info || { warn "Export VGA info failed"; export_failed=1; }
            export_drivers || { warn "Export drivers failed"; export_failed=1; }
            export_temperatures || { warn "Export temperatures failed"; export_failed=1; }
            export_boot_timing || { warn "Export boot timing failed"; export_failed=1; }
            export_network_interfaces || { warn "Export network interfaces failed"; export_failed=1; }
            export_summary || { warn "Export summary failed"; export_failed=1; }
            
            if [[ "$export_failed" -eq 1 ]]; then
                draw_box_line "${C_YELLOW}⚠ Some exports failed (check warnings above)${C_RESET}"
            else
                draw_box_line "${C_GREEN}✓ Export complete: ${OUTPUT_DIR}${C_RESET}"
            fi
        elif [[ "$SAVE_ALL" -eq 1 ]]; then
            printf '\n'
            draw_box_line "${C_CYAN}Exporting all logs to single file...${C_RESET}"
            if export_all_logs; then
                draw_box_line "${C_GREEN}✓ Export complete: ${OUTPUT_DIR}/arch-log-inspector-all.txt${C_RESET}"
            else
                draw_box_line "${C_RED}✗ Export failed (check warnings above)${C_RESET}"
            fi
        fi

        # Clear individual flags covered by SCAN_SYSTEM to prevent double execution
        SCAN_DRIVER=0 SCAN_VGA=0 SCAN_MOUNT=0 SCAN_USB=0
    fi

    # Individual scan flags (independent of SCAN_ALL/SCAN_SYSTEM)
    if [[ "$SCAN_DRIVER" -eq 1 ]]; then
        scan_drivers
    fi
    if [[ "$SCAN_VGA" -eq 1 ]]; then
        scan_vga_info
    fi
    if [[ "$SCAN_KERNEL" -eq 1 ]]; then
        scan_kernel_logs
    fi
    if [[ "$SCAN_USER" -eq 1 ]]; then
        scan_user_services
        scan_coredumps
    fi
    if [[ "$SCAN_MOUNT" -eq 1 ]]; then
        scan_mounts
    fi
    if [[ "$SCAN_USB" -eq 1 ]]; then
        scan_usb_devices
    fi

    # Export logic for individual flag combinations
    local any_individual_scan=0
    [[ "$SCAN_DRIVER" -eq 1 || "$SCAN_VGA" -eq 1 || "$SCAN_KERNEL" -eq 1 || "$SCAN_USER" -eq 1 || "$SCAN_MOUNT" -eq 1 || "$SCAN_USB" -eq 1 ]] && any_individual_scan=1

    if [[ "$any_individual_scan" -eq 1 && "$SAVE_LOGS" -eq 1 ]]; then
        printf '\n'
        draw_box_line "${C_CYAN}Exporting logs to ${OUTPUT_DIR}...${C_RESET}"

        local export_failed=0
        [[ "$SCAN_DRIVER" -eq 1 ]] && { export_drivers || { warn "Export drivers failed"; export_failed=1; }; }
        [[ "$SCAN_VGA" -eq 1 ]] && { export_vga_info || { warn "Export VGA info failed"; export_failed=1; }; }
        [[ "$SCAN_KERNEL" -eq 1 ]] && { export_kernel_logs || { warn "Export kernel logs failed"; export_failed=1; }; }
        [[ "$SCAN_USER" -eq 1 ]] && { export_user_services || { warn "Export user services failed"; export_failed=1; }; }
        [[ "$SCAN_USER" -eq 1 ]] && { export_coredumps || { warn "Export coredumps failed"; export_failed=1; }; }
        [[ "$SCAN_MOUNT" -eq 1 ]] && { export_mounts || { warn "Export mounts failed"; export_failed=1; }; }
        [[ "$SCAN_USB" -eq 1 ]] && { export_usb_devices || { warn "Export USB devices failed"; export_failed=1; }; }
        export_summary || { warn "Export summary failed"; export_failed=1; }

        if [[ "$export_failed" -eq 1 ]]; then
            draw_box_line "${C_YELLOW}⚠ Some exports failed (check warnings above)${C_RESET}"
        else
            draw_box_line "${C_GREEN}✓ Export complete: ${OUTPUT_DIR}${C_RESET}"
        fi
    fi

    # Footer
    printf '\n'
    draw_box_line "${C_GREEN}✓ Scan complete. This tool is read-only.${C_RESET}"
    printf '\n'
}

main "$@"

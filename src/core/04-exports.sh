# shellcheck shell=bash
# LOG EXPORT FUNCTIONS
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


    # Save original umask before setting restrictive mode
    # Use RETURN trap to guarantee restoration even if an exception occurs
    local old_umask
    old_umask="$(umask)"
    local _old_ret_trap
    _old_ret_trap="$(trap -p RETURN)"
    # shellcheck disable=SC2064
    trap "umask $old_umask; ${_old_ret_trap:-trap - RETURN}" RETURN

    # Set restrictive umask for log export (owner read/write only)
    umask 077

    # Check disk space before mutating global state
    if ! check_disk_space "$new_output_dir"; then
        warn "Insufficient disk space for export"
        return 1
    fi

    # Create directory
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

    # Limit to last 500 lines to avoid excessive memory usage
    journal_output="$(timeout 10 journalctl -k -p 3 -n 500 "${boot_args[@]}" --no-pager 2>/dev/null)" || true

    if [[ -z "$journal_output" ]]; then
        printf 'No kernel errors found for boot: %s\n' "${boot_args[*]}" > "$output_file"
        return 0
    fi

    # Write raw log
    printf '%s\n' "$journal_output" > "$output_file"

    # Write clustered version
    local clustered_file="${OUTPUT_DIR}/kernel_errors_clustered.txt"
    # Reuse cluster_errors() for consistent normalization with terminal output
    # cluster_errors() normalizes: addresses, PIDs, IRQs, CPUs, device names,
    # MAC addresses, port numbers, sector numbers — then sorts by frequency
    cluster_errors <<< "$journal_output" > "$clustered_file"

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

    # Limit to last 500 lines to avoid excessive memory usage
    journal_output="$(timeout 10 journalctl -u "*.service" -p 3 -n 500 "${boot_args[@]}" --no-pager 2>/dev/null)" || true

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

        # Use /proc/mounts directly (consistent with scan_mounts terminal output)
        # Filter: exclude autofs and comment lines, decode octal escapes
        while IFS=' ' read -r source target fstype opts rest; do
            [[ "$source" =~ ^# ]] && continue
            [[ "$fstype" == "autofs" ]] && continue
            # Decode /proc/mounts octal escapes (same as scan_mounts for consistency)
            # \040 = space, \011 = tab, \134 = backslash
            source="${source//\\040/ }"
            source="${source//\\011/$'\t'}"
            source="${source//\\134/\\}"
            target="${target//\\040/ }"
            target="${target//\\011/$'\t'}"
            target="${target//\\134/\\}"
            printf '%-30s %-30s %s\n' "$source" "$target" "$fstype"
        done < /proc/mounts 2>/dev/null || true

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
            # lsusb -v without root prints "Couldn't open device" to stdout
            # (not stderr), polluting export files — use -v only as root
            if [[ $EUID -eq 0 ]]; then
                timeout 15 lsusb -v 2>/dev/null | head -100 || true
            else
                timeout 15 lsusb 2>/dev/null || true
            fi
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
            _gather_temperatures | _format_temperatures_file
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

# ─────────────────────────────────────────────────────────────────────────────
# Helper: Generate network interfaces export content (reusable)
# Used by: export_network_interfaces(), export_all_logs()
# Output: Formatted text for export files (no color codes)
# ─────────────────────────────────────────────────────────────────────────────
_export_network_interfaces_content() {
    printf '=============================================================\n'
    printf 'NETWORK INTERFACES\n'
    printf '=============================================================\n\n'

    if [[ -d /sys/class/net ]]; then
        local _ng_was_set=0
        shopt -q nullglob && _ng_was_set=1
        local _old_ret_trap
        _old_ret_trap="$(trap -p RETURN)"
        shopt -s nullglob
        # shellcheck disable=SC2064
        trap "$(if [[ $_ng_was_set -eq 0 ]]; then echo 'shopt -u nullglob;'; else echo ':;'; fi) ${_old_ret_trap:-trap - RETURN}" RETURN

        printf '%-16s %-8s %-10s %-20s %s\n' 'Interface' 'State' 'Speed' 'MAC' 'IP'
        printf '%-16s %-8s %-10s %-20s %s\n' '─────────' '─────' '─────' '───' '──'
        for net_path in /sys/class/net/*; do
            [[ ! -d "$net_path" ]] && continue
            local iface_name
            iface_name="$(basename "$net_path")"
            [[ "$iface_name" == "lo" ]] && continue
            local e_state="unknown" e_speed="N/A" e_mac="N/A"
            [[ -f "${net_path}/operstate" ]] && e_state="$(< "${net_path}/operstate" 2>/dev/null)" || e_state="unknown"
            if [[ -f "${net_path}/speed" ]]; then
                local rs
                rs="$(< "${net_path}/speed" 2>/dev/null)" || rs=""
                if [[ -n "$rs" && "$rs" =~ ^[0-9]+$ && "$rs" -gt 0 ]]; then
                    if [[ "$rs" -ge 1000 ]]; then
                        e_speed="$((rs / 1000))Gbps"
                    else
                        e_speed="${rs}Mbps"
                    fi
                fi
            fi
            [[ -f "${net_path}/address" ]] && e_mac="$(< "${net_path}/address" 2>/dev/null)" || e_mac="N/A"
            local e_ip="N/A"
            if command -v ip &>/dev/null; then
                local ip_line=""
                ip_line="$(ip -br addr show dev "$iface_name" 2>/dev/null)" || ip_line=""
                if [[ "$ip_line" =~ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
                    e_ip="${BASH_REMATCH[1]}"
                elif [[ "$ip_line" =~ ([0-9a-fA-F:]{3,39}(/[0-9]+)?) ]]; then
                    e_ip="${BASH_REMATCH[1]}"
                fi
                [[ -z "$e_ip" ]] && e_ip="N/A"
            fi
            printf '%-16s %-8s %-10s %-20s %s\n' "$iface_name" "$e_state" "$e_speed" "$e_mac" "$e_ip"
        done
    else
        printf '/sys/class/net not available.\n'
    fi
}

export_network_interfaces() {
    # Guard: validate OUTPUT_DIR
    if [[ -z "$OUTPUT_DIR" || ! -d "$OUTPUT_DIR" ]]; then
        warn "export_network_interfaces: OUTPUT_DIR not set or invalid"
        return 1
    fi

    local output_file="${OUTPUT_DIR}/network_interfaces.txt"

    _export_network_interfaces_content > "$output_file"

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
            glxinfo 2>/dev/null | grep -E 'OpenGL (vendor|renderer|version)' | head -5 || true
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
    local driver_link

    local _ng_was_set=0
    shopt -q nullglob && _ng_was_set=1
    local _old_ret_trap
    _old_ret_trap="$(trap -p RETURN)"
    shopt -s nullglob
    # shellcheck disable=SC2064
    trap "$(if [[ $_ng_was_set -eq 0 ]]; then echo 'shopt -u nullglob;'; else echo ':;'; fi) ${_old_ret_trap:-trap - RETURN}" RETURN

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
        _get_lspci >/dev/null
        if [[ -n "$_LSPCI_CACHE" ]]; then
            printf '%s\n' "$_LSPCI_CACHE"
        else
            printf 'lspci not available\n'
        fi
        printf '\n\n'

        # Section 3: USB devices
        printf '=============================================================\n'
        printf '[3] USB DEVICES\n'
        printf '=============================================================\n\n'
        if command -v lsusb &>/dev/null; then
            # lsusb -v without root prints "Couldn't open device" to stdout
            if [[ $EUID -eq 0 ]]; then
                timeout 15 lsusb -v 2>/dev/null | head -100 || timeout 5 lsusb 2>/dev/null || true
            else
                timeout 5 lsusb 2>/dev/null || true
            fi
        else
            printf 'lsusb not available\n'
        fi
        printf '\n\n'

        # Section 4: DRM/GPU drivers
        printf '=============================================================\n'
        printf '[4] GPU/DRM DRIVERS\n'
        printf '=============================================================\n\n'
        if [[ -d /sys/class/drm ]]; then
            for card in /sys/class/drm/card*; do
                [[ ! -d "$card" ]] && continue
                printf 'Device: %s\n' "$(basename "$card")"
                if [[ -L "${card}/device/driver" ]]; then
                    # Extract basename using bash parameter expansion
                    driver_link="$(readlink "${card}/device/driver" 2>/dev/null)"
                    printf 'Driver: %s\n' "${driver_link##*/}"
                fi
                printf '\n'
            done
        else
            printf 'DRM subsystem not available\n'
        fi
        printf '\n'

        # Section 5: Network drivers
        printf '=============================================================\n'
        printf '[5] NETWORK DRIVERS\n'
        printf '=============================================================\n\n'
        if [[ -d /sys/class/net ]]; then
            for iface in /sys/class/net/*; do
                [[ ! -d "$iface" ]] && continue
                local iface_name
                iface_name="$(basename "$iface")"
                printf 'Interface: %s\n' "$iface_name"
                if [[ -L "${iface}/device/driver" ]]; then
                    # Extract basename using bash parameter expansion
                    driver_link="$(readlink "${iface}/device/driver" 2>/dev/null)"
                    printf 'Driver: %s\n' "${driver_link##*/}"
                fi
                printf '\n'
            done
        else
            printf 'Network subsystem not available\n'
        fi
        printf '\n'

        # Section 6: Audio drivers
        printf '=============================================================\n'
        printf '[6] AUDIO DRIVERS\n'
        printf '=============================================================\n\n'
        if [[ -d /sys/class/sound ]]; then
            for sound in /sys/class/sound/*; do
                [[ ! -d "$sound" ]] && continue
                printf 'Device: %s\n' "$(basename "$sound")"
                if [[ -L "${sound}/device/driver" ]]; then
                    # Extract basename using bash parameter expansion
                    driver_link="$(readlink "${sound}/device/driver" 2>/dev/null)"
                    printf 'Driver: %s\n' "${driver_link##*/}"
                fi
                printf '\n'
            done
        else
            printf 'Sound subsystem not available\n'
        fi
        printf '\n'

        # Section 7: Storage drivers
        printf '=============================================================\n'
        printf '[7] STORAGE DRIVERS\n'
        printf '=============================================================\n\n'
        if [[ -d /sys/block ]]; then
            for block in /sys/block/*; do
                [[ ! -d "$block" ]] && continue
                local bname
                bname="$(basename "$block")"
                printf 'Device: %s\n' "$bname"
                if [[ -L "${block}/device/driver" ]]; then
                    # Extract basename using bash parameter expansion
                    driver_link="$(readlink "${block}/device/driver" 2>/dev/null)"
                    printf 'Driver: %s\n' "${driver_link##*/}"
                fi
                printf '\n'
            done
        else
            printf 'Block subsystem not available\n'
        fi
        printf '\n'

        # Section 8: Input drivers
        printf '=============================================================\n'
        printf '[8] INPUT/HID DRIVERS\n'
        printf '=============================================================\n\n'
        if [[ -d /sys/class/input ]]; then
            for input in /sys/class/input/*; do
                [[ ! -d "$input" ]] && continue
                printf 'Device: %s\n' "$(basename "$input")"
                if [[ -L "${input}/device/driver" ]]; then
                    # Extract basename using bash parameter expansion
                    driver_link="$(readlink "${input}/device/driver" 2>/dev/null)"
                    printf 'Driver: %s\n' "${driver_link##*/}"
                fi
                printf '\n'
            done
        else
            printf 'Input subsystem not available\n'
        fi
        printf '\n'

        # Section 9: Platform drivers
        printf '=============================================================\n'
        printf '[9] PLATFORM DRIVERS\n'
        printf '=============================================================\n\n'
        if [[ -d /sys/bus/platform/drivers ]]; then
            # Use glob instead of ls parsing (safe with special chars)
            local count=0
            for d in /sys/bus/platform/drivers/*/; do
                [[ -d "$d" ]] || continue
                printf '%s\n' "${d##*/}"
                count=$((count + 1))
                [[ "$count" -ge 50 ]] && break
            done
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
            # Use glob instead of ls parsing (safe with special chars)
            local found=0
            for d in /sys/bus/pci/drivers/*/; do
                [[ -d "$d" ]] || continue
                local driver_name="${d##*/}"
                if [[ "$driver_name" =~ virtio|vmware|vbox|xen|qxl ]]; then
                    printf '%s\n' "$driver_name"
                    found=1
                fi
            done
            [[ "$found" -eq 0 ]] && printf 'No virtual drivers detected\n'
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
    local _ng_was_set=0
    shopt -q nullglob && _ng_was_set=1
    local _old_ret_trap
    _old_ret_trap="$(trap -p RETURN)"
    shopt -s nullglob
    # shellcheck disable=SC2064
    trap "$(if [[ $_ng_was_set -eq 0 ]]; then echo 'shopt -u nullglob;'; else echo ':;'; fi) ${_old_ret_trap:-trap - RETURN}" RETURN

    for f in "$OUTPUT_DIR"/*.txt; do
        bname="$(basename "$f")"
        if [[ "$bname" != "summary.txt" ]]; then
            fname="$bname"
            lines="$(wc -l < "$f")"
            printf '  - %s (%s lines)\n' "$fname" "$lines" >> "$output_file"
        fi
    done

    printf '\n=============================================================\n' >> "$output_file"
    info "Summary exported: summary.txt"
}

# ─────────────────────────────────────────────────────────────────────────────
# CONSOLIDATED EXPORT
# ─────────────────────────────────────────────────────────────────────────────

# Safely extract a trap command string without eval vulnerabilities
# This converts `trap -p` output back into a raw string suitable for `trap -- "$cmd" SIGNAL`
# avoiding the use of `eval` which breaks on nested quotes or tainted input.
#
# trap -p format: trap -- 'COMMAND' SIGNAL
# where COMMAND may contain nested quotes escaped as '\'' (end-quote, escaped-quote, start-quote)
#
# Special handling: trap '' SIGNAL (ignore) vs trap - SIGNAL (default) are different!
# - trap '' EXIT → ignore the signal
# - trap - EXIT → reset to default handler
# We use __IGNORE__ sentinel to preserve the ignore state during extraction.
_extract_trap_cmd() {
    local sig="$1"
    local var_name="$2"
    local t trap_output
    trap_output="$(trap -p "$sig")"

    if [[ -z "$trap_output" ]]; then
        # No trap set at all
        printf -v "$var_name" ""
        return
    fi

    # Check for trap - SIGNAL (default handler)
    if [[ "$trap_output" == "trap - $sig" || "$trap_output" == "trap - SIG$sig" ]]; then
        printf -v "$var_name" ""
        return
    fi

    # Check for trap '' SIGNAL (ignore signal)
    if [[ "$trap_output" == "trap '' $sig" || "$trap_output" == "trap '' SIG$sig" ]]; then
        printf -v "$var_name" "__IGNORE__"
        return
    fi

    # Extract command from: trap -- 'command' SIGNAL
    # Use parameter expansion instead of regex to handle multi-line commands
    # (bash regex .* doesn't match newlines)
    # Format: trap -- '...' SIGNAL
    t="${trap_output#trap -- }"
    t="${t% $sig}"
    t="${t% SIG$sig}"

    # Extract content between outer single quotes
    # Handle multi-line commands where bash escapes newlines as literal \n in the string
    if [[ "$t" =~ ^\'(.*)\'$ ]]; then
        t="${BASH_REMATCH[1]}"
    else
        # Fallback: strip leading/trailing quotes manually
        t="${t#\'}"
        t="${t%\'}"
    fi

    # Check for empty command (trap '' SIGNAL)
    if [[ -z "$t" ]]; then
        printf -v "$var_name" "__IGNORE__"
        return
    fi

    # Unescape bash's safe-escaped single quotes: '\'' → '
    t="${t//\'\\\'\'/\'}"

    printf -v "$var_name" "%s" "$t"
}

# ─────────────────────────────────────────────────────────────────────────────
# EXPORT ALL LOGS TO SINGLE FILE
# ─────────────────────────────────────────────────────────────────────────────

# Global variables for export cleanup (used by _export_cleanup)
# These are set by export_all_logs and consumed by the cleanup handler
declare -g _EXPORT_CLEANUP_TEMP_FILE=""
declare -g _EXPORT_CLEANUP_OLD_EXIT=""
declare -g _EXPORT_CLEANUP_OLD_INT=""
declare -g _EXPORT_CLEANUP_OLD_TERM=""

# Restore caller's traps and clean up export temp file.
# Usage: _export_restore_cleanup_state [keep_temp_file]
#   keep_temp_file=0 (default): delete temp file (error/interrupt path)
#   keep_temp_file=1: preserve temp file (success path, already moved)
_export_restore_cleanup_state() {
    local keep_temp_file="${1:-0}"

    # Restore caller's traps first (before any other operations)
    if [[ -n "${_EXPORT_CLEANUP_OLD_EXIT:-}" ]]; then
        if [[ "$_EXPORT_CLEANUP_OLD_EXIT" == "__IGNORE__" ]]; then trap '' EXIT
        else trap -- "$_EXPORT_CLEANUP_OLD_EXIT" EXIT; fi
    else
        trap - EXIT
    fi
    if [[ -n "${_EXPORT_CLEANUP_OLD_INT:-}" ]]; then
        if [[ "$_EXPORT_CLEANUP_OLD_INT" == "__IGNORE__" ]]; then trap '' INT
        else trap -- "$_EXPORT_CLEANUP_OLD_INT" INT; fi
    else
        trap - INT
    fi
    if [[ -n "${_EXPORT_CLEANUP_OLD_TERM:-}" ]]; then
        if [[ "$_EXPORT_CLEANUP_OLD_TERM" == "__IGNORE__" ]]; then trap '' TERM
        else trap -- "$_EXPORT_CLEANUP_OLD_TERM" TERM; fi
    else
        trap - TERM
    fi

    # Clean up temp file if it exists and we're not preserving it
    if [[ "$keep_temp_file" -eq 0 && -n "${_EXPORT_CLEANUP_TEMP_FILE:-}" && -f "${_EXPORT_CLEANUP_TEMP_FILE}" ]]; then
        rm -f "$_EXPORT_CLEANUP_TEMP_FILE" 2>/dev/null
    fi
}

# Cleanup handler for export_all_logs when invoked by EXIT/INT/TERM traps.
_export_cleanup() {
    local exit_code=$?
    _export_restore_cleanup_state 0
    exit "$exit_code"
}

export_all_logs() {
    local -a boot_args=(-b "$BOOT_OFFSET")
    local driver_link=""

    # Guard: validate OUTPUT_DIR
    if [[ -z "$OUTPUT_DIR" || ! -d "$OUTPUT_DIR" ]]; then
        warn "export_all_logs: OUTPUT_DIR not set or invalid"
        return 1
    fi

    local output_file="${OUTPUT_DIR}/arch-log-inspector-all.txt"

    # Save caller's traps to avoid side-effect
    # trap is GLOBAL in bash — clearing it affects caller
    # Store in global variables for _export_cleanup handler
    _extract_trap_cmd EXIT _EXPORT_CLEANUP_OLD_EXIT
    _extract_trap_cmd INT _EXPORT_CLEANUP_OLD_INT
    _extract_trap_cmd TERM _EXPORT_CLEANUP_OLD_TERM

    # Set cleanup trap for EXIT, INT (Ctrl+C), and TERM
    # _export_cleanup will restore caller's traps and clean up temp file
    trap _export_cleanup EXIT INT TERM

    # Create temp file and store in global variable for cleanup handler
    _EXPORT_CLEANUP_TEMP_FILE="$(mktemp)" || {
        warn "Failed to create temp file (disk full or /tmp unavailable)"
        _export_restore_cleanup_state 0
        return 1
    }

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

        # Pre-check: is journald running?
        # Helps prevent delays on systems where systemd-journald is stopped/restarting
        local journald_available=0
        if command -v journalctl &>/dev/null && \
           journalctl --no-pager -n 0 &>/dev/null; then
            journald_available=1
        fi

        # ─────────────────────────────────────────────────────────────────────
        # KERNEL LOGS
        # ─────────────────────────────────────────────────────────────────────
        printf '=============================================================\n'
        printf '[1] KERNEL LOGS (Priority ≤3 - Errors)\n'
        printf '=============================================================\n'
        local kernel_output
        if [[ "$journald_available" -eq 1 ]]; then
            kernel_output="$(timeout 5 journalctl -k -p 3 -n 500 "${boot_args[@]}" --no-pager 2>/dev/null)" || true
        fi
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
        if [[ "$journald_available" -eq 1 ]]; then
            service_output="$(timeout 5 journalctl -u "*.service" -p 3 -n 500 "${boot_args[@]}" --no-pager 2>/dev/null)" || true
        fi
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
        printf '=============================================================\n\n'

        # Check if Arch-based system before attempting to read pacman log
        if [[ "$DISTRO_TYPE" != "Arch-based" && "$DISTRO_TYPE" != "Performance Tuned" && \
              "$DISTRO_NAME" != *"Arch"* && "$DISTRO_NAME" != *"CachyOS"* ]]; then
            printf 'Skipping pacman scan (non-Arch system)\n'
            printf 'Note: pacman is the package manager for Arch Linux\n\n'
        else
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
        fi
        printf '\n'

        # ─────────────────────────────────────────────────────────────────────
        # MOUNTED FILESYSTEMS
        # ─────────────────────────────────────────────────────────────────────
        printf '=============================================================\n'
        printf '[7] MOUNTED FILESYSTEMS\n'
        printf '=============================================================\n'
        if [[ -f /proc/mounts ]]; then
            while read -r device mountpt fstype rest; do
                [[ "$fstype" == "autofs" ]] && continue
                mountpt="${mountpt//\\040/ }"
                mountpt="${mountpt//\\011/$'\t'}"
                mountpt="${mountpt//\\134/\\}"
                printf '%s on %s type %s\n' "$device" "$mountpt" "$fstype"
            done < /proc/mounts 2>/dev/null || true
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
            # lsusb -v without root prints "Couldn't open device" to stdout
            if [[ $EUID -eq 0 ]]; then
                timeout 15 lsusb -v 2>/dev/null | head -100 || true
            else
                timeout 15 lsusb 2>/dev/null || true
            fi
        else
            printf 'lsusb not available.\n'
        fi
        printf '\n\n'

        # ─────────────────────────────────────────────────────────────────────
        # NETWORK INTERFACES
        # ─────────────────────────────────────────────────────────────────────
        printf '=============================================================\n'
        printf '[10] NETWORK INTERFACES\n'
        printf '=============================================================\n\n'
        _export_network_interfaces_content
        printf '\n'
        # ─────────────────────────────────────────────────────────────────────
        printf '=============================================================\n'
        printf '[11] GPU / VGA INFO\n'
        printf '=============================================================\n'
        printf 'Graphics Card: %s\n\n' "${GPU_INFO}"
        printf 'Display: %s\n\n' "${DISPLAY_INFO}"
        if command -v glxinfo &>/dev/null; then
            printf 'OpenGL Info:\n'
            glxinfo 2>/dev/null | grep -E 'OpenGL (vendor|renderer|version)' | head -5 || true
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
        printf 'Network Status: %s\n' "$INTERNET_STATUS"
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
            local _ng_was_set=0
            shopt -q nullglob && _ng_was_set=1
            shopt -s nullglob
            local temp_found=0
            for hw_dir in /sys/class/hwmon/hwmon*; do
                [[ ! -d "$hw_dir" ]] && continue
                local hw_name=""
                [[ -f "${hw_dir}/name" ]] && hw_name="$(<"${hw_dir}/name")"
                for ti in "${hw_dir}"/temp*_input; do
                    [[ ! -f "$ti" ]] && continue
                    local tr_val
                    tr_val="$(< "$ti" 2>/dev/null)" || continue
                    [[ -z "$tr_val" || ! "$tr_val" =~ ^-?[0-9]+$ ]] && continue
                    local lbl_file="${ti%_input}_label"
                    local lbl="${hw_name:-hwmon}"
                    [[ -f "$lbl_file" ]] && lbl="$(< "$lbl_file" 2>/dev/null)" || lbl="${hw_name:-hwmon}"
                    printf '  %s/%s: %d°C\n' "${hw_name:-hwmon}" "$lbl" $((tr_val / 1000))
                    temp_found=1
                done
            done
            if [[ "$_ng_was_set" -eq 0 ]]; then
                shopt -u nullglob
            fi
            [[ "$temp_found" -eq 0 ]] && printf '  No temperature sensors detected.\n'
        else
            printf '  hwmon not available.\n'
        fi
        printf '\n\n'

        printf '=============================================================\n'
        printf 'END OF LOG EXPORT\n'
        printf '=============================================================\n'

    } > "$_EXPORT_CLEANUP_TEMP_FILE"

    # Validate temp file before moving (detect partial writes)
    if [[ ! -s "$_EXPORT_CLEANUP_TEMP_FILE" ]]; then
        warn "Temp file is empty (possible write failure): $_EXPORT_CLEANUP_TEMP_FILE"
        _export_restore_cleanup_state 0
        return 1
    fi

    # Move temp file to final location
    if ! mv "$_EXPORT_CLEANUP_TEMP_FILE" "$output_file"; then
        warn "Failed to move temp file to $output_file"
        _export_restore_cleanup_state 0
        return 1
    fi

    # SUCCESS: Restore caller traps (temp file was moved to final output path)
    _export_restore_cleanup_state 1

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
            --boot)
                # Support space-separated format: --boot -1
                if [[ $# -lt 2 ]]; then
                    die "Missing value for --boot (use: --boot N or --boot=N)"
                fi
                BOOT_OFFSET="$2"
                # Validate numeric
                if ! [[ "$BOOT_OFFSET" =~ ^-?[0-9]+$ ]]; then
                    die "Invalid boot offset: $BOOT_OFFSET (must be integer)"
                fi
                # Validate reasonable range (systemd typically keeps 10-20 boots)
                # Tighter bounds prevent DoS via resource exhaustion
                if [[ "$BOOT_OFFSET" -lt -50 || "$BOOT_OFFSET" -gt 50 ]]; then
                    die "Boot offset out of range: $BOOT_OFFSET (must be between -50 and 50)"
                fi
                shift 2
                ;;
            --boot=*)
                BOOT_OFFSET="${arg#--boot=}"
                # Validate numeric
                if ! [[ "$BOOT_OFFSET" =~ ^-?[0-9]+$ ]]; then
                    die "Invalid boot offset: $BOOT_OFFSET (must be integer)"
                fi
                # Validate reasonable range (systemd typically keeps 10-20 boots)
                # Tighter bounds prevent DoS via resource exhaustion
                if [[ "$BOOT_OFFSET" -lt -50 || "$BOOT_OFFSET" -gt 50 ]]; then
                    die "Boot offset out of range: $BOOT_OFFSET (must be between -50 and 50)"
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
            --)
                # End-of-options marker (POSIX convention)
                # All remaining arguments are treated as positional (ignored for this script)
                # Usage: ./arch-diag.sh -- --kernel  # runs full scan, ignores --kernel
                shift
                break
                ;;
            *)
                die "Unknown argument: $arg (use --help for usage)"
                ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────

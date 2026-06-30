# shellcheck shell=bash
# DISTRO & SYSTEM FINGERPRINTING
# ─────────────────────────────────────────────────────────────────────────────

detect_distro() {
    local id="" variant=""

    if [[ -f /etc/os-release ]]; then
        # Parse ID and ID_LIKE from os-release
        # -m1: only first match (avoid multi-line edge case)
        # -f2-: keep rest of line if value contains '='
        id="$(grep -m1 '^ID=' /etc/os-release | cut -d'=' -f2- | tr -d '"')" || id="unknown"
        variant="$(grep -m1 '^ID_LIKE=' /etc/os-release | cut -d'=' -f2- | tr -d '"')" || variant=""
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

    # CPU Governor detection
    # File may exist but be unreadable (permission denied)
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
        CPU_GOVERNOR="$(</sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)" || CPU_GOVERNOR="unknown"
        # Trim whitespace and handle empty result
        CPU_GOVERNOR="${CPU_GOVERNOR//[[:space:]]/}"
        [[ -z "$CPU_GOVERNOR" ]] && CPU_GOVERNOR="unknown"
    elif command -v cpupower &>/dev/null; then
        # Parse governor from cpupower output format:
        #   The governor "performance" may decide which speed to use
        # NOT from "current policy: frequency..." line (wrong format)
        CPU_GOVERNOR="$(cpupower frequency-info 2>/dev/null | \
            sed -n 's/.*The governor "\([^"]*\)".*/\1/p' | head -1)"
        CPU_GOVERNOR="${CPU_GOVERNOR:-unknown}"
    else
        CPU_GOVERNOR="unknown"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# SYSTEM DETECTION
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# NETWORK STATUS DETECTION
# ─────────────────────────────────────────────────────────────────────────────

# Detect network status (NOT internet connectivity)
# Sets INTERNET_STATUS to one of:
#   - "connected": Verified internet access (only when ARLOGKN_CHECK_EXTERNAL=1)
#   - "ip_assigned": Has routable IP but not verified (default behavior)
#   - "link_up": Interface up but no IP
#   - "disconnected": No connectivity detected
#
# Note: Function name is legacy — "check_internet" is misleading because:
# - Default behavior only checks for IP assignment, not actual internet
# - Return code is always 0 (success) for ip_assigned/link_up
# - Caller ignores return code (check_internet || true)
# - True internet check requires ARLOGKN_CHECK_EXTERNAL=1 (opt-in)
#
# Better name would be detect_network_status(), but keeping for backward compat.
detect_network_status() {
    # Network status check — local methods first, external only if enabled
    # routable IP ≠ internet connectivity (VPN, isolated namespace, etc.)
    # Status: ip_assigned, link_up, connected, disconnected

    # ─────────────────────────────────────────────────────────────────────────
    # METHOD 1: Check interface operstate + IP from /sys
    # ─────────────────────────────────────────────────────────────────────────
    if [[ -d /sys/class/net ]]; then
        local iface operstate iface_name
        local has_link_up=0
        local found_physical_ip=0
        local found_virtual_ip=0
        
        # Collect all interfaces with valid IPs (don't early return)
        # Priority: physical interfaces (eth*, enp*, wlp*) > virtual (docker*, tun*, br-*)
        for iface in /sys/class/net/*; do
            [[ -e "$iface" ]] || continue
            iface_name="$(basename "$iface")"
            # Skip loopback interface
            [[ "$iface_name" == "lo" ]] && continue

            # Check if interface is UP
            if [[ -f "${iface}/operstate" ]]; then
                operstate="$(< "${iface}/operstate" 2>/dev/null)" || operstate=""
                if [[ "$operstate" == "up" ]]; then
                    # Interface is UP — check for routable IP assignment
                    if command -v ip &>/dev/null; then
                        local ip_output has_valid_ip=0

                        # Check IPv4 (exclude link-local 169.254.x.x)
                        ip_output="$(ip -4 addr show "$iface_name" 2>/dev/null)"
                        if printf '%s\n' "$ip_output" | grep -qE 'inet [0-9]' && \
                           ! printf '%s\n' "$ip_output" | grep -q 'inet 169\.254\.'; then
                            has_valid_ip=1
                        fi

                        # Check IPv6 (exclude link-local fe80::/10 and loopback ::1)
                        if [[ "$has_valid_ip" -eq 0 ]]; then
                            ip_output="$(ip -6 addr show "$iface_name" 2>/dev/null)"
                            if printf '%s\n' "$ip_output" | grep -qE 'inet6 [0-9a-f]' && \
                               ! printf '%s\n' "$ip_output" | grep -qE 'inet6 (fe80:|::1)'; then
                                has_valid_ip=1
                            fi
                        fi

                        if [[ "$has_valid_ip" -eq 1 ]]; then
                            # Categorize interface: physical vs virtual/overlay
                            # Physical: eth*, enp*, eno*, ens*, wlp*, wlan* (priority)
                            # Virtual: docker*, tun*, tap*, br-*, veth*, virbr* (lower priority)
                            if [[ "$iface_name" =~ ^(eth|enp|eno|ens|wlp|wlan) ]]; then
                                found_physical_ip=1
                            else
                                found_virtual_ip=1
                            fi
                        fi
                    fi
                    # No ip command or no valid IP — mark as link up
                    has_link_up=1
                fi
            fi
        done

        # Priority: physical interface with IP > virtual interface with IP > link up
        if [[ "$found_physical_ip" -eq 1 ]]; then
            INTERNET_STATUS="ip_assigned"
        elif [[ "$found_virtual_ip" -eq 1 ]]; then
            INTERNET_STATUS="ip_assigned"
        elif [[ "$has_link_up" -eq 1 ]]; then
            INTERNET_STATUS="link_up"
        fi
    fi

    # ─────────────────────────────────────────────────────────────────────────
    # OPTIONAL: External connectivity checks (only if explicitly enabled)
    # This is the ONLY path that sets "connected" (verified internet access)
    # ─────────────────────────────────────────────────────────────────────────
    if [[ "${ARLOGKN_CHECK_EXTERNAL:-0}" == "1" ]]; then
        # Try gateway ping first (more reliable than hardcoded 8.8.8.8)
        # Use single awk process instead of grep | awk | head pipeline (3 forks → 1 fork)
        local gateway=""
        if command -v ip &>/dev/null; then
            gateway="$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')"
        fi

        if [[ -n "$gateway" ]] && command -v ping &>/dev/null; then
            if ping -c1 -W2 "$gateway" &>/dev/null; then
                INTERNET_STATUS="connected"
                return 0
            fi
        fi

        # Fallback to HTTP check with configurable endpoint
        # Security: Validate URL scheme and host to prevent SSRF attacks
        # Only allow https:// scheme with safe, public endpoints
        local test_url="${ARLOGKN_TEST_URL:-https://clients3.google.com/generate_204}"
        
        # Validate URL format: must start with https:// (no file://, gopher://, http://, etc.)
        # Prevents: SSRF via malicious ARLOGKN_TEST_URL, internal network probing
        if [[ ! "$test_url" =~ ^https:// ]]; then
            warn "ARLOGKN_TEST_URL: invalid scheme (must be https://), using default"
            test_url="https://clients3.google.com/generate_204"
        fi
        
        # Block private/internal IP ranges to prevent internal network probing
        # Exclude: 10.x.x.x, 172.16-31.x.x, 192.168.x.x, 127.x.x.x, 169.254.x.x, 0.0.0.0, localhost, ::1, [::1], [::]
        # Exclude IPv6 ULA (fc00::/7) and Link-Local (fe80::/10)
        if [[ "$test_url" =~ https://(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.|169\.254\.|0\.0\.0\.0|localhost|::1|\[::1\]|\[::\]|\[?[fF][cCdD][0-9a-fA-F]*:|\[?[fF][eE][89aAbB][0-9a-fA-F]*:) ]]; then
            warn "ARLOGKN_TEST_URL: blocked private/internal endpoint, using default"
            test_url="https://clients3.google.com/generate_204"
        fi

        if command -v curl &>/dev/null; then
            local http_code
            http_code="$(curl -s --head --connect-timeout 2 --max-time 3 \
                 -o /dev/null -w '%{http_code}' "$test_url" 2>/dev/null)"
            # Accept 2xx (success) or 204 (captive portal check)
            if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
                INTERNET_STATUS="connected"
                return 0
            fi
        fi
    fi

    # Final decision based on whatever highest state we reached
    if [[ "$INTERNET_STATUS" == "ip_assigned" || "$INTERNET_STATUS" == "link_up" ]]; then
        return 0
    fi

    INTERNET_STATUS="disconnected"
    return 1
}

# Backward compatibility alias
# Guard with || true: detect_network_status() returns 1 on disconnect,
# which would kill the script under set -e if called without || true.
# Callers should check $INTERNET_STATUS instead of return code.
check_internet() { detect_network_status "$@" || true; }

detect_gpu() {
    # GPU detection - try /sys filesystem first
    local gpu_names=()
    local driver_link=""
    
    # Collect GPU names in subshell - nullglob auto-cleans on subshell exit
    # This avoids trap clobber issue (trap - EXIT destroys caller's trap)
    mapfile -t gpu_names < <(
        shopt -s nullglob
        for card_path in /sys/class/drm/card[0-9]*; do
            [[ ! -d "$card_path" ]] && continue

            # Skip render nodes and connector entries (e.g., card0-HDMI-A-1)
            [[ "$card_path" == *"render"* ]] && continue
            [[ "$(basename "$card_path")" == *-* ]] && continue

            driver=""
            if [[ -L "${card_path}/device/driver" ]]; then
                # Extract basename using bash parameter expansion
                driver_link="$(readlink "${card_path}/device/driver" 2>/dev/null)"
                [[ -n "$driver_link" ]] && driver="${driver_link##*/}"
            fi

            gpu_name=""
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
            esac

            [[ -n "$gpu_name" ]] && printf '%s\n' "$gpu_name"
        done
        shopt -u nullglob
    )

    # Build GPU info string (supports multiple GPUs)
    if [[ ${#gpu_names[@]} -gt 0 ]]; then
        # Remove duplicates using pure bash (no subprocesses)
        local -A seen
        local -a unique=()
        local name
        for name in "${gpu_names[@]}"; do
            if [[ -z "${seen[$name]:-}" ]]; then
                unique+=("$name")
                seen[$name]=1
            fi
        done
        # Join with ", " using pure bash
        # Note: "${array[*]}" only uses FIRST char of IFS, so we must join manually
        local i
        GPU_INFO="${unique[0]}"
        for ((i=1; i<${#unique[@]}; i++)); do
            GPU_INFO="${GPU_INFO}, ${unique[i]}"
        done
    else
        GPU_INFO=""
    fi

    # Fallback to lspci if available and no GPU detected yet
    # Use _get_lspci() for caching + timeout protection (prevents hang on broken PCI bus)
    if [[ -z "$GPU_INFO" ]] && command -v lspci &>/dev/null; then
        local lspci_output
        lspci_output="$(_get_lspci)"
        GPU_INFO="$(printf '%s\n' "$lspci_output" | grep -iE 'vga|3d|display' | head -1 | cut -d':' -f3- | sed 's/^ *//')"
    fi

    # Final fallback to lshw (with timeout to prevent hang)
    if [[ -z "$GPU_INFO" ]] && command -v lshw &>/dev/null; then
        GPU_INFO="$(timeout 5 lshw -class display 2>/dev/null | grep -m1 'product:' | cut -d':' -f2 | sed 's/^ *//')" || GPU_INFO=""
    fi

    GPU_INFO="${GPU_INFO:-Unknown}"
}

detect_display() {
    # Display detection — check DRM connectors from /sys (works without X11/Wayland)
    local -a display_parts=()
    local status name connector_dir res modes_file entry

    # Save nullglob state and restore on RETURN (guards against set -e early exit)
    # Critical: this function runs in main shell context (not subshell),
    # so nullglob leak here affects ALL subsequent code
    local _ng_was_set=0
    shopt -q nullglob && _ng_was_set=1
    local _old_ret_trap
    _old_ret_trap="$(trap -p RETURN)"
    shopt -s nullglob
    # shellcheck disable=SC2064
    trap "$(if [[ $_ng_was_set -eq 0 ]]; then echo 'shopt -u nullglob;'; else echo ':;'; fi) ${_old_ret_trap:-trap - RETURN}" RETURN

    for connector in /sys/class/drm/card*/card*-*/status; do
        [[ ! -f "$connector" ]] && continue
        status="$(< "$connector" 2>/dev/null)" || status=""
        if [[ "$status" == "connected" ]]; then
            connector_dir="$(dirname "$connector")"
            name="$(basename "$connector_dir")"
            name="${name#card*-}"  # Remove "card*-" prefix

            # Get resolution from THIS connector's modes file
            res=""
            modes_file="${connector_dir}/modes"
            if [[ -f "$modes_file" ]]; then
                res="$(head -1 "$modes_file" 2>/dev/null)"
                # Defense-in-depth: sanitize against ANSI injection
                # (VM/passthrough GPU drivers may write unexpected data)
                res="$(printf '%s' "$res" | \
                    sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b\][^\x07]*\x07//g; s/\x1b[^[]*//g' | \
                    tr -d '[:cntrl:]')"
            fi

            entry="${name}"
            [[ -n "$res" ]] && entry="${entry} ($res)"
            display_parts+=("$entry")
        fi
    done

    if [[ ${#display_parts[@]} -gt 0 ]]; then
        DISPLAY_INFO="$(printf '%s, ' "${display_parts[@]}")"
        DISPLAY_INFO="${DISPLAY_INFO%, }"  # Remove trailing comma+space
        return 0
    fi

    # Fallback: check if any DRM device exists
    # nullglob is already set — no need for separate toggle
    local -a cards=()
    if [[ -d /sys/class/drm ]]; then
        cards=(/sys/class/drm/card[0-9]*)
    fi
    if [[ ${#cards[@]} -gt 0 && -e "${cards[0]}" ]]; then
        DISPLAY_INFO="DRM active (no connected display)"
        return 0
    fi

    DISPLAY_INFO="No display detected"
}

# ─────────────────────────────────────────────────────────────────────────────
# DRIVER DETECTION
# ─────────────────────────────────────────────────────────────────────────────

# Helper: Get driver from /sys/class device link
get_driver_from_sys() {
    local class_path="$1"
    local driver=""

    if [[ -L "${class_path}/device/driver" ]]; then
        # Extract basename using bash parameter expansion (no subprocess)
        # Use plain readlink: we only need basename, -f is unnecessary and can fail on dangling symlinks
        local driver_link
        driver_link="$(readlink "${class_path}/device/driver" 2>/dev/null)" || driver_link=""

        if [[ -n "$driver_link" ]]; then
            driver="${driver_link##*/}"  # Extract basename
        fi
    fi
    printf '%s\n' "$driver"
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: Detect drivers from /sys/class (GPU, network, audio)
# Returns: gpu_driver|network_driver|audio_driver (pipe-separated, 3 fields)
# ─────────────────────────────────────────────────────────────────────────────
_detect_drivers_sysclass() {
    local gpu_driver="N/A" network_driver="N/A" audio_driver="N/A"

    # Save nullglob state and restore on RETURN (guards against set -e early exit)
    local _ng_was_set=0
    shopt -q nullglob && _ng_was_set=1
    local _old_ret_trap
    _old_ret_trap="$(trap -p RETURN)"
    shopt -s nullglob
    # shellcheck disable=SC2064
    trap "$(if [[ $_ng_was_set -eq 0 ]]; then echo 'shopt -u nullglob;'; else echo ':;'; fi) ${_old_ret_trap:-trap - RETURN}" RETURN

    # GPU from DRM
    if [[ -d /sys/class/drm ]]; then
        local card_path driver
        for card_path in /sys/class/drm/card[0-9]*; do
            [[ ! -d "$card_path" ]] && continue
            [[ "$(basename "$card_path")" == *-* ]] && continue
            driver="$(get_driver_from_sys "$card_path")"
            [[ -n "$driver" && "$driver" != "N/A" ]] && gpu_driver="$driver"
        done
    fi

    # Network from net class
    if [[ -d /sys/class/net ]]; then
        local net_path iface_driver
        local -a net_drvs=()
        local -A seen_net_drvs=()
        for net_path in /sys/class/net/*; do
            [[ ! -d "$net_path" ]] && continue
            [[ "$(basename "$net_path")" == "lo" ]] && continue
            iface_driver="$(get_driver_from_sys "$net_path")"
            if [[ -n "$iface_driver" && "$iface_driver" != "N/A" ]]; then
                if [[ -z "${seen_net_drvs[$iface_driver]:-}" ]]; then
                    seen_net_drvs["$iface_driver"]=1
                    net_drvs+=("$iface_driver")
                fi
            fi
        done

        if [[ ${#net_drvs[@]} -gt 0 ]]; then
            network_driver="$(printf '%s, ' "${net_drvs[@]}")"
            network_driver="${network_driver%, }"
        fi
    fi

    # Audio from sound class
    if [[ -d /sys/class/sound ]]; then
        local sound_path audio_drv
        for sound_path in /sys/class/sound/*; do
            [[ ! -d "$sound_path" ]] && continue
            audio_drv="$(get_driver_from_sys "$sound_path")"
            [[ -n "$audio_drv" && "$audio_drv" != "N/A" ]] && audio_driver="$audio_drv" && break
        done
    fi

    printf '%s|%s|%s\n' "$gpu_driver" "$network_driver" "$audio_driver"
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: Extract driver from lspci output for devices matching pattern
# Input: $1 = pattern (regex), $2 = lspci_output
# Returns: driver name or empty string
# Uses awk to respect device boundaries (lines starting with XX:XX.X)
# Prevents false match where grep -A2 would grab driver from NEXT device
# ─────────────────────────────────────────────────────────────────────────────
_lspci_get_driver() {
    local pattern="$1"
    local lspci_output="$2"
    # Use tolower() for case-insensitive matching (POSIX-compatible, works on mawk/nawk/gawk)
    # IGNORECASE=1 is GNU awk extension, not portable
    printf '%s\n' "$lspci_output" | awk -v pat="$pattern" '
    BEGIN { found=0 }
    /^[0-9a-f]+:[0-9a-f.]+/ { found=0 }  # New device: reset flag
    tolower($0) ~ pat { found=1 }         # Match pattern: set flag (case-insensitive)
    /Kernel driver/ && found {            # Driver line + flag set
        sub(/.*Kernel driver in use: /, "")
        print
        exit
    }
    '
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: Detect drivers from lspci -k output
# Input: $1 = lspci_output
# Returns: storage|usb|thunderbolt|nvme|smbus|platform (6 fields)
# Note: sata_driver and i2c_driver are detected from lsmod (not lspci)
#       because lspci cannot distinguish SATA/AHCI or I2C module variants
# ─────────────────────────────────────────────────────────────────────────────
_detect_drivers_lspci() {
    local lspci_output="$1"
    local storage_driver="N/A" usb_driver="N/A" thunderbolt_driver="N/A"
    local nvme_driver="N/A" smbus_driver="N/A" platform_driver="N/A"

    # Storage controllers
    storage_driver="$(_lspci_get_driver 'sata|ahci|ide|storage' "$lspci_output")"
    [[ -z "$storage_driver" ]] && storage_driver="N/A"

    # NVMe
    nvme_driver="$(_lspci_get_driver 'nvme' "$lspci_output")"
    [[ -z "$nvme_driver" ]] && nvme_driver="N/A"

    # USB Controller
    usb_driver="$(_lspci_get_driver 'usb|xhci|ehci|ohci|uhci' "$lspci_output")"
    [[ -z "$usb_driver" ]] && usb_driver="N/A"

    # Thunderbolt
    thunderbolt_driver="$(_lspci_get_driver 'thunderbolt' "$lspci_output")"
    [[ -z "$thunderbolt_driver" ]] && thunderbolt_driver="N/A"

    # I2C/SMBus (combined — lspci cannot distinguish I2C from SMBus reliably)
    smbus_driver="$(_lspci_get_driver 'smbus|i2c' "$lspci_output")"
    [[ -z "$smbus_driver" ]] && smbus_driver="N/A"

    # ISA/LPC Bridge (platform)
    # Prioritize ISA/LPC matches (specific platform bridges), then fallback to PCH/platform
    # Avoid generic 'bridge' pattern which matches PCIe/SATA bridges incorrectly
    platform_driver="$(_lspci_get_driver 'isa bridge|lpc bridge|isa|lpc' "$lspci_output")"
    if [[ -z "$platform_driver" ]]; then
        platform_driver="$(_lspci_get_driver 'platform|pch' "$lspci_output")"
    fi
    [[ -z "$platform_driver" ]] && platform_driver="N/A"

    printf '%s|%s|%s|%s|%s|%s\n' \
        "$storage_driver" "$usb_driver" "$thunderbolt_driver" "$nvme_driver" \
        "$smbus_driver" "$platform_driver"
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: Detect drivers from /sys/bus and /sys/class (virtual, input, watchdog)
# Returns: virtual|input|watchdog (3 fields)
# ─────────────────────────────────────────────────────────────────────────────
_detect_drivers_sysbus() {
    local virtual_driver="N/A" input_driver="N/A" watchdog_driver="N/A"

    # Save nullglob state and restore on RETURN (guards against set -e early exit)
    local _ng_was_set=0
    shopt -q nullglob && _ng_was_set=1
    local _old_ret_trap
    _old_ret_trap="$(trap -p RETURN)"
    shopt -s nullglob
    # shellcheck disable=SC2064
    trap "$(if [[ $_ng_was_set -eq 0 ]]; then echo 'shopt -u nullglob;'; else echo ':;'; fi) ${_old_ret_trap:-trap - RETURN}" RETURN

    # Virtual drivers from /sys/bus/pci/drivers
    if [[ -d /sys/bus/pci/drivers ]]; then
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
    fi

    # Input drivers from /sys/class/input
    if [[ -d /sys/class/input ]]; then
        local -a input_drvs=()
        local -A seen_input_drvs=()
        local input_path
        for input_path in /sys/class/input/*; do
            [[ ! -d "$input_path" ]] && continue
            local inp_drv
            inp_drv="$(get_driver_from_sys "$input_path")"
            if [[ -n "$inp_drv" && "$inp_drv" != "N/A" ]]; then
                if [[ -z "${seen_input_drvs[$inp_drv]:-}" ]]; then
                    seen_input_drvs["$inp_drv"]=1
                    input_drvs+=("$inp_drv")
                fi
            fi
        done
        # Join unique drivers with ", "
        if [[ ${#input_drvs[@]} -gt 0 ]]; then
            input_driver="$(printf '%s, ' "${input_drvs[@]}")"
            input_driver="${input_driver%, }"
        fi
    fi

    # Watchdog
    if [[ -d /sys/class/watchdog ]]; then
        local wd_path
        for wd_path in /sys/class/watchdog/*; do
            [[ ! -d "$wd_path" ]] && continue
            local wd_drv
            wd_drv="$(get_driver_from_sys "$wd_path")"
            [[ -n "$wd_drv" && "$wd_drv" != "N/A" ]] && watchdog_driver="$wd_drv" && break
        done
        [[ -z "$watchdog_driver" || "$watchdog_driver" == "N/A" ]] && watchdog_driver="N/A"
    fi

    printf '%s|%s|%s\n' "$virtual_driver" "$input_driver" "$watchdog_driver"
}

# Main driver detection - multi-source
# Orchestrates 3 helper functions and merges results
detect_drivers() {
    # Return cached result if available (drivers don't change during session)
    # Use printf instead of echo to avoid xpg_echo interpretation of -e, -n flags
    [[ -n "$_DRIVERS_CACHE" ]] && printf '%s\n' "$_DRIVERS_CACHE" && return 0

    local lsmod_output
    lsmod_output="$(timeout 5 lsmod 2>/dev/null)" || true
    # Count loaded modules (skip header line)
    # Use NR>1{count++} to avoid -1 on empty input (awk with 0 bytes → NR=0 → NR-1=-1)
    # count+0 ensures 0 is printed even if count is unset (empty input)
    local loaded_count
    loaded_count="$(awk 'NR>1{count++} END{print count+0}' <<< "$lsmod_output")"

    # Initialize all driver variables with defaults
    local gpu_driver="N/A" network_driver="N/A" audio_driver="N/A"
    local storage_driver="N/A" usb_driver="N/A" thunderbolt_driver="N/A"
    local input_driver="N/A" platform_driver="N/A" virtual_driver="N/A"
    local nvme_driver="N/A" sata_driver="N/A" raid_driver="N/A"
    local i2c_driver="N/A" smbus_driver="N/A" watchdog_driver="N/A"

    # ─────────────────────────────────────────────────────────────────────────
    # SOURCE 1: /sys/class detection (GPU, network, audio)
    # ─────────────────────────────────────────────────────────────────────────
    local sysclass_result
    sysclass_result="$(_detect_drivers_sysclass)"
    IFS='|' read -r gpu_driver network_driver audio_driver <<< "$sysclass_result"

    # ─────────────────────────────────────────────────────────────────────────
    # SOURCE 2: lspci -k fallback/enhancement
    # ─────────────────────────────────────────────────────────────────────────
    if command -v lspci &>/dev/null; then
        # Use cached lspci output (single subprocess per session)
        local lspci_output
        lspci_output="$(_get_lspci)"

        # GPU fallback (enhanced patterns) - only if /sys didn't find it
        # Use tolower() for case-insensitive matching (POSIX-compatible)
        # IGNORECASE=1 is GNU awk extension, not portable
        [[ "$gpu_driver" == "N/A" ]] && gpu_driver="$(printf '%s\n' "$lspci_output" | awk '
            BEGIN { found=0 }
            /^[0-9a-f]+:[0-9a-f.]+/ { found=0 }
            tolower($0) ~ /vga|3d|display/ { found=1 }
            /Kernel driver/ && found {
                sub(/.*Kernel driver in use: /, "")
                print
                exit
            }
        ')"
        [[ -z "$gpu_driver" ]] && gpu_driver="N/A"

        # Network fallback
        # Use tolower() for case-insensitive matching (POSIX-compatible)
        [[ "$network_driver" == "N/A" ]] && network_driver="$(printf '%s\n' "$lspci_output" | awk '
            BEGIN { found=0 }
            /^[0-9a-f]+:[0-9a-f.]+/ { found=0 }
            tolower($0) ~ /ethernet|network|wireless|wifi/ { found=1 }
            /Kernel driver/ && found {
                sub(/.*Kernel driver in use: /, "")
                print
                exit
            }
        ')"
        [[ -z "$network_driver" ]] && network_driver="N/A"

        # Audio fallback
        # Use tolower() for case-insensitive matching (POSIX-compatible)
        [[ "$audio_driver" == "N/A" ]] && audio_driver="$(printf '%s\n' "$lspci_output" | awk '
            BEGIN { found=0 }
            /^[0-9a-f]+:[0-9a-f.]+/ { found=0 }
            tolower($0) ~ /audio|hdmi|hd-audio/ { found=1 }
            /Kernel driver/ && found {
                sub(/.*Kernel driver in use: /, "")
                print
                exit
            }
        ')"
        [[ -z "$audio_driver" ]] && audio_driver="N/A"

        # Parse remaining drivers from lspci (6 fields)
        # Note: sata_driver and i2c_driver are detected from lsmod, not lspci
        local lspci_result
        lspci_result="$(_detect_drivers_lspci "$lspci_output")"
        IFS='|' read -r storage_driver usb_driver thunderbolt_driver nvme_driver \
            smbus_driver platform_driver <<< "$lspci_result"
    fi

    # ─────────────────────────────────────────────────────────────────────────
    # SOURCE 3: /sys/bus detection (virtual, input, watchdog)
    # ─────────────────────────────────────────────────────────────────────────
    local sysbus_result
    sysbus_result="$(_detect_drivers_sysbus)"
    IFS='|' read -r virtual_driver input_driver watchdog_driver <<< "$sysbus_result"

    # ─────────────────────────────────────────────────────────────────────────
    # SOURCE 4: lsmod category detection (RAID, SATA, I2C enhancement)
    # ─────────────────────────────────────────────────────────────────────────

    # RAID detection
    if printf '%s\n' "$lsmod_output" | grep -qE '^raid|^dm_raid'; then
        raid_driver="mdraid/dm-raid"
    fi

    # SATA enhancement
    if [[ "$sata_driver" == "N/A" ]] && printf '%s\n' "$lsmod_output" | grep -qE '^ahci|^sata_'; then
        sata_driver="$(printf '%s\n' "$lsmod_output" | grep -E '^ahci|^sata_' | head -1 | awk '{print $1}')"
        [[ -z "$sata_driver" ]] && sata_driver="N/A"
    fi

    # I2C enhancement
    if [[ "$i2c_driver" == "N/A" ]] && printf '%s\n' "$lsmod_output" | grep -qE '^i2c_'; then
        i2c_driver="$(printf '%s\n' "$lsmod_output" | grep -E '^i2c_' | head -1 | awk '{print $1}')"
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
    [[ -z "$smbus_driver" ]] && smbus_driver="N/A"
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
    printf '%s\n' "$result"
}

# ─────────────────────────────────────────────────────────────────────────────
# UI / BOX DRAWING
# ─────────────────────────────────────────────────────────────────────────────

draw_header() {
    local title="$1"
    local width="${2:-70}"
    local title_visible_len
    visible_len "$title" title_visible_len
    local padding=$((width - title_visible_len - 2))
    if [[ $padding -lt 0 ]]; then
        padding=0
        # Optional: could truncate the title, but for headers it's usually better to just draw it full
    fi
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
    visible_len "$content" content_visible_len

    # Truncate if too long
    # Note: ${var:0:N} behavior depends on locale:
    # - UTF-8 locale (default): indexes by CHARACTER (correct for truncation)
    # - C/POSIX locale: indexes by BYTE (may cut multibyte chars)
    # Script does not set locale, so behavior is environment-dependent.
    # In UTF-8 locale (99% of modern systems), this works correctly.
    # Trade-off: Correct truncation > Color preservation
    if [[ $content_visible_len -gt $inner_width ]]; then
        local truncate_at=$((inner_width - 3))
        local stripped
        strip_ansi "$content" stripped
        content="${stripped:0:$truncate_at}..."
        content_visible_len=$((truncate_at + 3))
    fi

    local padding=$((inner_width - content_visible_len))
    if [[ $padding -lt 0 ]]; then
        padding=0
    fi

    printf ' %s %*s\n' "$content" "$padding" ""
}

# shellcheck disable=SC2120
draw_empty_box() {
    local width="${1:-70}"
    local message="✓ No Critical Issues Found"
    local msg_len
    visible_len "$message" msg_len
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
    visible_len "$full_line" full_visible_len
    local padding=$((inner_width - full_visible_len))

    if [[ $padding -lt 0 ]]; then
        padding=0
    fi

    printf ' %s%s%*s%s\n' "$C_BOLD" "$full_line" "$padding" "" "$C_RESET"
}

# ─────────────────────────────────────────────────────────────────────────────
# HARDWARE TEMPERATURE SCANNING
# ─────────────────────────────────────────────────────────────────────────────

# Helper: Gather temperature data from /sys/class/hwmon
# Output format: chip_name|label|temp_c (pipe-separated, one per line)
#
# IMPORTANT: This function is designed to be piped to _format_temperatures_display:
#   _gather_temperatures | _format_temperatures_display
#
# The entire table lifecycle (begin→rows→end) occurs within _format_temperatures_display,
# which runs in a subshell due to the pipeline. This is INTENTIONAL and SAFE because:
# 1. All table state changes (_TBL_DEPTH, etc.) are contained within the subshell
# 2. The subshell's output (formatted text) propagates to stdout correctly
# 3. Parent shell's table state is not affected
#
# WARNING FOR FUTURE MODIFICATIONS:
# - Do NOT call tbl_begin in parent shell and tbl_row inside _format_temperatures_display
# - Do NOT expect table state to propagate from _format_temperatures_display to parent
# - If you need table state in parent, refactor to use temp file or process substitution:
#     _gather_temperatures > "$temp_file"
#     _format_temperatures_display < "$temp_file"
# This pattern ensures table state consistency across subshell boundaries.
_gather_temperatures() {
    if [[ ! -d /sys/class/hwmon ]]; then
        return 1
    fi

    shopt -s nullglob
    for hwmon_dir in /sys/class/hwmon/hwmon*; do
        [[ ! -d "$hwmon_dir" ]] && continue

        # Get chip name
        local chip_name=""
        if [[ -f "${hwmon_dir}/name" ]]; then
            chip_name="$(<"${hwmon_dir}/name")"
        fi

        for temp_input in "${hwmon_dir}"/temp*_input; do
            [[ ! -f "$temp_input" ]] && continue

            local temp_raw
            temp_raw="$(<"$temp_input")" || continue

            # Skip non-numeric values
            if [[ -z "$temp_raw" || ! "$temp_raw" =~ ^-?[0-9]+$ ]]; then
                continue
            fi

            # Validate temperature bounds (-100°C to +150°C) in millidegrees
            if [[ "$temp_raw" -lt -100000 || "$temp_raw" -gt 150000 ]]; then
                continue
            fi

            # Convert millidegrees to degrees
            local temp_c=$((temp_raw / 1000))

            # Get label
            local label_file="${temp_input%_input}_label"
            local label
            if [[ -f "$label_file" ]]; then
                label="$(<"$label_file")"
            else
                label="${chip_name:-hwmon}"
            fi

            # Sanitize pipe characters to prevent breaking the IFS='|' parser
            local clean_chip="${chip_name:-hwmon}"
            clean_chip="${clean_chip//|/_}"
            local clean_label="${label//|/_}"

            # Output: chip_name|label|temp_c
            printf '%s|%s|%d\n' "$clean_chip" "$clean_label" "$temp_c"
        done
    done
    shopt -u nullglob
}

# Helper: Format temperature data for terminal display (with colors)
# CONTRACT: Must be called via pipeline from _gather_temperatures:
#   _gather_temperatures | _format_temperatures_display
#
# SUBSHELL DESIGN:
# This function runs in a SUBSHELL (pipeline vế phải). It is SELF-CONTAINED:
# - Calls draw_table_begin, tbl_row, draw_table_end entirely within subshell
# - Table state (_TBL_DEPTH, _TBL_COLS_STACK, etc.) does NOT propagate to parent
# - Output (formatted text) propagates to stdout correctly
#
# DESIGN LIABILITY:
# If parent shell calls tbl_begin/tbl_end around this pipeline, table stack
# will be DESYNCED (parent expects tbl_end but subshell already called it).
# Current scan_temperatures() avoids this by NOT wrapping the pipeline in
# table calls — the table is entirely within the subshell.
#
# DO NOT MODIFY to:
# - Call tbl_begin without matching tbl_end (breaks table state in subshell)
# - Expect table state to be visible in parent shell (won't work)
# - Split table lifecycle across subshell boundaries (will corrupt state)
# - Add tbl_begin/tbl_end around the pipeline in caller (will desync stack)
#
# See _gather_temperatures() for alternative patterns using temp files.
_format_temperatures_display() {
    local found=0
    draw_table_begin "Sensor" 30 "Temperature" 18

    while IFS='|' read -r chip_name label temp_c; do
        [[ -z "$chip_name" ]] && continue

        # Color-code by severity
        local color="$C_GREEN"
        [[ "$temp_c" -gt 60 ]] && color="$C_YELLOW"
        [[ "$temp_c" -gt 80 ]] && color="$C_RED"

        tbl_row "${chip_name}/${label}" "${color}${temp_c}°C${C_RESET}"
        found=1
    done

    draw_table_end

    if [[ "$found" -eq 0 ]]; then
        draw_box_line "${C_YELLOW}No temperature sensors detected${C_RESET}"
    fi
}

# Helper: Format temperature data for file export (plain text)
_format_temperatures_file() {
    printf '%-30s %s\n' 'Sensor' 'Temperature'
    printf '%-30s %s\n' '──────────────' '───────────'

    while IFS='|' read -r chip_name label temp_c; do
        [[ -z "$chip_name" ]] && continue
        printf '%-30s %d°C\n' "${chip_name}/${label}" "$temp_c"
    done
}

scan_temperatures() {
    draw_section_header "HARDWARE TEMPERATURES"
    printf '\n'

    if [[ ! -d /sys/class/hwmon ]]; then
        draw_box_line "${C_YELLOW}hwmon subsystem not available${C_RESET}"
        return 0
    fi

    _gather_temperatures | _format_temperatures_display
}

# ─────────────────────────────────────────────────────────────────────────────
# BOOT TIMING ANALYSIS
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
    # systemd-analyze blame does NOT support --boot=N in most versions
    local blame_output
    if [[ "$BOOT_OFFSET" -ne 0 ]]; then
        draw_box_line "${C_YELLOW}⚠ blame not available for boot offset ${BOOT_OFFSET} (systemd-analyze blame only supports current boot)${C_RESET}"
        blame_output=""
    else
        blame_output="$(systemd-analyze blame --no-pager 2>/dev/null | head -10)" || true
    fi

    if [[ -n "$blame_output" ]]; then
        draw_box_line "${C_BOLD}Top 10 Slowest Services:${C_RESET}"
        printf '%s%*s%s\n' "$C_CYAN" 70 "" "$C_RESET"

        printf '%s\n' "$blame_output" | while read -r line; do
            [[ -z "$line" ]] && continue

            # Extract service name (last word) and full time string
            local unit="${line##* }"
            local time_str="${line% "$unit"}"
            # Trim leading/trailing spaces (extglob enabled globally at script start)
            time_str="${time_str##+([[:space:]])}"
            time_str="${time_str%%+([[:space:]])}"
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
                    # Integer truncation: 31.9 → 31 (fast, no subshell)
                    # For coloring threshold (5s/10s), truncation is sufficient
                    local extra_sec="${BASH_REMATCH[1]%.*}"
                    extra_sec="${extra_sec:-0}"
                    time_sec=$((time_sec + extra_sec))
                fi
            elif [[ "$time_val" =~ ^([0-9]+\.?[0-9]*)s$ ]]; then
                # Integer truncation: 4.9 → 4, 5.1 → 5 (fast, no subshell)
                # For coloring threshold, truncation is conservative (safe)
                time_sec="${BASH_REMATCH[1]%.*}"
                time_sec="${time_sec:-0}"
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
# NETWORK INTERFACE SCANNING
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
        [[ -f "${net_path}/operstate" ]] && state="$(< "${net_path}/operstate" 2>/dev/null)" || state="unknown"

        # Read speed (may not exist for wireless or down interfaces)
        local speed="N/A"
        if [[ -f "${net_path}/speed" ]]; then
            local raw_speed
            raw_speed="$(< "${net_path}/speed" 2>/dev/null)" || raw_speed=""
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

    # Read /proc/mounts ONCE into array to avoid race condition
    # (NFS automount or other dynamic mounts could change between reads)
    # Filter: exclude autofs and comment lines
    # Use Unit Separator (ASCII 31) as delimiter — safe for paths with '|'
    local -a mount_lines=()
    local delim=$'\x1F'  # Unit Separator (control char, invalid in filenames)
    while IFS=' ' read -r source target fstype opts freq pass; do
        [[ "$source" =~ ^# ]] && continue
        [[ "$fstype" == "autofs" ]] && continue
        mount_lines+=("${source}${delim}${target}${delim}${fstype}")
    done < /proc/mounts 2>/dev/null || true

    local filtered_total=${#mount_lines[@]}
    local count=0

    for line in "${mount_lines[@]}"; do
        [[ $count -ge 12 ]] && break

        # Parse Unit-Separator-delimited fields
        IFS="$delim" read -r source target fstype <<< "$line"

        # Decode /proc/mounts octal escapes (pure bash, no subprocess)
        # /proc/mounts encodes: space→\040, tab→\011, backslash→\134
        # Without decoding, paths like "/mnt/my\040drive" display wrong
        # and fail comparison with actual filesystem paths
        source="${source//\\040/ }"
        source="${source//\\011/$'\t'}"
        source="${source//\\134/\\}"
        target="${target//\\040/ }"
        target="${target//\\011/$'\t'}"
        target="${target//\\134/\\}"

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
    done

    # Warn if truncated (servers with many mounts: NFS, btrfs subvolumes, containers)
    if [[ "$filtered_total" -gt "$count" ]]; then
        draw_box_line "${C_YELLOW}... and $((filtered_total - count)) more mounts${C_RESET}"
    fi

    draw_table_end

    # Disk usage - extract to helper to avoid 'local' in pipeline subshell
    _render_disk_usage_table
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: Render disk usage table from df output
# Called by scan_mounts()
#
# DESIGN: Uses process substitution instead of pipeline to avoid subshell issue.
# Pipeline: df | while read → tbl_row runs in SUBSHELL (cannot modify parent state)
# Process substitution: while read < <(df) → tbl_row runs in CURRENT shell
#
# This matters because tbl_begin/tbl_row/tbl_end use global state (_TBL_DEPTH, etc.)
# that must be modified in the current shell, not a subshell copy.
# ─────────────────────────────────────────────────────────────────────────────
_render_disk_usage_table() {
    draw_section_header "DISK USAGE"
    draw_table_begin "Filesystem" 24 "Size" 9 "Used" 9 "Avail" 9 "Use%" 6

    # Use process substitution to avoid pipeline subshell
    # while read < <(command) runs in current shell, not subshell
    while IFS='|' read -r fs size used avail usep; do
        local color="$C_RESET"
        local use_num="${usep%\%}"
        # Validate use_num is numeric before arithmetic comparison
        # df can return "-" for unavailable filesystems (e.g., NFS timeout)
        # Without validation, [[ "-" -gt 90 ]] throws bash arithmetic syntax error
        if [[ "$use_num" =~ ^[0-9]+$ ]]; then
            # Use if/elif to prevent overwriting: 95% should be RED, not YELLOW
            if [[ "$use_num" -gt 90 ]]; then
                color="$C_RED"
            elif [[ "$use_num" -gt 70 ]]; then
                color="$C_YELLOW"
            fi
        fi
        # Non-numeric values (e.g., "-") remain $C_RESET (no color)
        draw_table_row "${color}${fs}${C_RESET}" "$size" "$used" "$avail" "$usep"
    done < <(df -h 2>/dev/null | awk 'NR>1 && /^\/dev\// {print $1"|"$2"|"$3"|"$4"|"$5}' | sort -u | head -6)

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

    # Save and set nullglob — restore on RETURN to prevent leak to caller
    local _ng_was_set=0
    shopt -q nullglob && _ng_was_set=1
    local _old_ret_trap
    _old_ret_trap="$(trap -p RETURN)"
    shopt -s nullglob
    # shellcheck disable=SC2064
    trap "$(if [[ $_ng_was_set -eq 0 ]]; then echo 'shopt -u nullglob;'; else echo ':;'; fi) ${_old_ret_trap:-trap - RETURN}" RETURN

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
        # Use $(<file) instead of $(cat file) to avoid fork overhead per device
        vendor="$(< "$dev_path/idVendor" 2>/dev/null)" || vendor=""
        [[ -z "$vendor" ]] && continue  # Skip if no vendor ID

        dev_id="$(< "$dev_path/devnum" 2>/dev/null)" || dev_id="?"
        bus_id="$(< "$dev_path/busnum" 2>/dev/null)" || bus_id="?"

        # Try product first, then manufacturer as fallback
        product="$(< "$dev_path/product" 2>/dev/null)" || product=""
        if [[ -z "$product" || "$product" =~ ^[[:cntrl:]]*$ ]]; then
            manufacturer="$(< "$dev_path/manufacturer" 2>/dev/null)" || manufacturer=""
            [[ -n "$manufacturer" && ! "$manufacturer" =~ ^[[:cntrl:]]*$ ]] && product="$manufacturer"
        fi

        # Clean product name (defense-in-depth: strip ANSI escapes + control chars)
        # 1. Strip ANSI CSI sequences: \x1b[...letter (e.g., \x1b[2J = clear screen)
        # 2. Strip ANSI OSC sequences: \x1b]...BEL   (e.g., \x1b]0;title\x07 = set title)
        # 3. Strip bare ESC not caught above: \x1b followed by anything
        # 4. Strip remaining control characters (belt-and-suspenders for locale edge cases)
        # 5. Trim whitespace
        # Why explicit ANSI strip before tr: [:cntrl:] is locale-dependent;
        # in non-C locales, \x1b may not be classified as control character
        product="$(printf '%s' "$product" | \
            sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b\][^\x07]*\x07//g; s/\x1b[^[]*//g' | \
            tr -d '[:cntrl:]' | \
            sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

        # Fallback product name
        [[ -z "$product" ]] && product="USB Device"

        # Determine device type from product name (case-insensitive matching)
        local dev_type="Other"
        local product_lower="${product,,}"  # Convert to lowercase for matching
        case "$product_lower" in
            *keyboard*) dev_type="Keyboard" ;;
            *mouse*) dev_type="Mouse" ;;
            *hub*) dev_type="Hub" ;;
            *storage*|*flash*|*disk*|*mass*|*sd*|*card*) dev_type="Storage" ;;
            *webcam*|*camera*) dev_type="Camera" ;;
            *controller*|*receiver*|*wireless*|*dongle*) dev_type="Controller" ;;
            *audio*|*headset*|*speaker*|*headphone*) dev_type="Audio" ;;
        esac

        # Read product ID from sysfs
        local product_id
        product_id="$(< "$dev_path/idProduct" 2>/dev/null)" || product_id="??"

        # Truncate product name to 29 characters (use character-aware truncation for UTF-8)
        local product_truncated
        truncate_str "$product" 29 product_truncated
        draw_table_row "${vendor}:${product_id}" "$product_truncated" "Bus ${bus_id}" "$dev_type"
        count=$((count + 1))
    done
    # nullglob restored by RETURN trap

    draw_table_end

    # USB storage - check via /sys/block (no lsblk needed)
    draw_section_header "USB STORAGE"

    local found_storage=0
    draw_table_begin "Device" 8 "Size" 10 "Model" 20 "Mount" 18

    # nullglob already enabled (set at function entry, restored by RETURN trap)
    for block in /sys/block/*; do
        [[ ! -d "$block" ]] && continue
        local bname
        bname="$(basename "$block")"

        # Check if it's a USB device (sd* or mmc*)
        [[ ! "$bname" =~ ^(sd[a-z]+|mmcblk[0-9]+)$ ]] && continue

        # Check if removable (USB drives are removable)
        local removable="0"
        if [[ -f "$block/removable" ]]; then
            removable="$(< "$block/removable" 2>/dev/null)"
            [[ -z "$removable" ]] && removable="0"
        fi
        [[ "$removable" != "1" ]] && continue

        found_storage=1
        local size="?" model="" mount=""

        if [[ -f "$block/size" ]]; then
            size="$(< "$block/size" 2>/dev/null)"
            [[ -z "$size" ]] && size="?"
        fi
        [[ -n "$size" && "$size" != "?" ]] && size="$((size / 2 / 1024 / 1024))Gi"

        if [[ -f "$block/device/vendor" ]]; then
            model="$(< "$block/device/vendor" 2>/dev/null)"
        fi
        if [[ -f "$block/device/model" ]]; then
            local dev_model
            dev_model="$(< "$block/device/model" 2>/dev/null)"
            [[ -n "$dev_model" ]] && model="$model $dev_model"
        fi
        [[ -z "$model" ]] && model="USB Storage"

        # Check mount point from /proc/mounts
        # Decode octal escapes: space=\040, tab=\011, backslash=\134
        mount="$(grep "^/dev/${bname}" /proc/mounts 2>/dev/null | awk '{print $2}' | head -1)"
        mount="${mount//\\040/ }"
        mount="${mount//\\011/$'\t'}"
        mount="${mount//\\134/\\}"
        [[ -z "$mount" ]] && mount="<unmounted>"

        # Truncate model and mount to fit table columns (use character-aware truncation for UTF-8)
        local model_truncated mount_truncated
        truncate_str "$model" 19 model_truncated
        truncate_str "$mount" 17 mount_truncated
        draw_table_row "/dev/${bname}" "$size" "$model_truncated" "$mount_truncated"
    done
    # nullglob restored by RETURN trap

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
        # Cache glxinfo output (can take 0.5-1s per call if X server is busy)
        # Use -B (brief) flag: -s does not exist and causes silent failure
        local glx_output glx_vendor glx_renderer
        glx_output="$(glxinfo -B 2>/dev/null)" || glx_output=""
        glx_vendor="$(printf '%s\n' "$glx_output" | grep 'OpenGL vendor' | cut -d':' -f2 | sed 's/^ *//')"
        glx_renderer="$(printf '%s\n' "$glx_output" | grep 'OpenGL renderer' | cut -d':' -f2 | sed 's/^ *//')"
        
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

    # Note: || true prevents set -e exit when drivers_info is empty (read returns 1 on EOF)
    IFS='|' read -r loaded_count gpu_drv net_drv audio_drv storage_drv \
        usb_drv thunderbolt_drv input_drv platform_drv virtual_drv \
        nvme_drv sata_drv raid_drv i2c_drv smbus_drv watchdog_drv \
        <<< "$drivers_info" || true

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

    # Network status (not internet — having IP ≠ internet access)
    local network_icon
    case "$INTERNET_STATUS" in
        "connected")
            # External connectivity verified via HTTP/gateway check
            network_icon="${C_GREEN}✓ Connected${C_RESET}"
            ;;
        "ip_assigned")
            # Has routable IP but external connectivity not verified
            network_icon="${C_YELLOW}▲ IP Assigned (unverified)${C_RESET}"
            ;;
        "link_up")
            # Interface UP but no IP confirmed
            network_icon="${C_YELLOW}▲ Link Up (no IP)${C_RESET}"
            ;;
        *)
            # disconnected or unknown
            network_icon="${C_RED}✗ Disconnected${C_RESET}"
            ;;
    esac
    draw_box_line "${C_BOLD}Network:${C_RESET} ${network_icon}"

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
                # Validate numeric fields before arithmetic (kernel may report '-' for zram)
                [[ ! "$size" =~ ^[0-9]+$ ]] && continue
                [[ ! "$used" =~ ^[0-9]+$ ]] && continue
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
                    algo="$(< "${zram_dev}/comp_algorithm")" 2>/dev/null
                    algo="$(printf '%s' "$algo" | sed 's/.*\[\([^]]*\)\].*/\1/')"
                    disksize_bytes="$(< "${zram_dev}/disksize")" 2>/dev/null || disksize_bytes=0
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
        # Use --output to avoid line wrapping with long device paths (LVM, dm-crypt, ZFS)
        # df -h / --output=size,used,avail produces:
        #   Size Used Avail
        #    20G   10G   10G
        local df_output
        df_output="$(df -h / --output=size,used,avail 2>/dev/null | tail -1)"
        # Trim leading/trailing whitespace and parse fields
        read -r disk_total disk_used disk_avail <<< "$df_output"
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

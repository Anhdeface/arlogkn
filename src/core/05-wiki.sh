# shellcheck shell=bash
# WIKI GROUP DEFINITIONS
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

# ─────────────────────────────────────────────────────────────────────────────
# WIKI FUZZY MATCHING
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# Helper: AWK-based Levenshtein distance with O(min(m,n)) space optimization
# Uses 2-row technique instead of full m×n matrix to reduce memory usage
#
# SINGLE source of truth for Levenshtein algorithm in this script.
# Both best-match and suggestions modes use the SAME implementation.
#
# Modes:
#   - "best": Returns best_idx:best_dist (for awk_fuzzy_match)
#   - "suggest": Returns top 3 suggestions sorted by distance (for suggest_wiki_groups)
# ─────────────────────────────────────────────────────────────────────────────
# Usage:
#   result=$(printf '%s\n' "$groups" | _wiki_awk "$query" "best")
#   result=$(printf '%s\n' "$groups" | _wiki_awk "$query" "suggest")
_wiki_awk() {
    local query="$1"
    local mode="${2:-best}"
    
    awk -v q="$query" -v mode="$mode" '
function min3(a, b, c) {
    return (a < b) ? ((a < c) ? a : c) : ((b < c) ? b : c)
}
# Optimized Levenshtein with O(min(m,n)) space using 2-row technique
# Instead of storing full m×n matrix, only keep current and previous rows
# Reduces memory from O(m×n) to O(min(m,n)) — critical for many comparisons
function levenshtein(s1, s2,    len1, len2, i, j, prev, curr, c1, c2, cost, tmp) {
    len1 = length(s1); len2 = length(s2)
    if (len1 == 0) return len2
    if (len2 == 0) return len1

    # Ensure s2 is shorter for minimal space usage
    if (len1 > len2) { tmp = s1; s1 = s2; s2 = tmp; tmp = len1; len1 = len2; len2 = tmp }

    # Initialize previous row (represents row 0 of matrix)
    # Only need len1+1 entries (shorter string length), not len2+1
    split("", prev)
    split("", curr)
    for (j = 0; j <= len1; j++) prev[j] = j

    # Process each character of s2 (longer string)
    for (i = 1; i <= len2; i++) {
        curr[0] = i  # First column of current row
        c2 = substr(s2, i, 1)

        # Compute current row from previous row
        for (j = 1; j <= len1; j++) {
            c1 = substr(s1, j, 1)
            cost = (c1 == c2) ? 0 : 1
            curr[j] = min3(prev[j] + 1, curr[j-1] + 1, prev[j-1] + cost)
        }

        # Copy current row to previous row for next iteration
        # Using array copy instead of split("", prev) to preserve allocated memory
        for (j = 0; j <= len1; j++) prev[j] = curr[j]
    }

    return prev[len1]
}
function get_threshold(len) {
    if (len <= 4) return 1
    if (len <= 8) return 2
    return 3
}
BEGIN {
    best_idx = -1
    best_dist = 999
    count = 0
}
{
    idx = NR - 1
    split($0, parts, " ")
    
    # Match against ALL words in group name, not just first word
    # This allows matching "managment" → "management" in "pacman package management"
    # Use best (lowest) distance among all words for threshold check
    best_word_dist = 999
    best_word_len = 0
    
    for (p = 1; p in parts; p++) {
        word = parts[p]
        dist = levenshtein(q, word)
        if (dist < best_word_dist) {
            best_word_dist = dist
            best_word_len = length(word)
        }
    }
    
    dist = best_word_dist
    threshold = get_threshold(best_word_len)

    if (mode == "best") {
        # Best-match mode: track closest match only
        if (dist <= threshold && dist < best_dist) {
            best_dist = dist
            best_idx = idx
            if (dist == 0) exit
        }
    } else {
        # Suggestions mode: collect all matches within threshold
        if (dist <= threshold) {
            suggestions[++count] = $0
            distances[count] = dist
        }
    }
}
END {
    if (mode == "suggest") {
        # Sort suggestions by distance (ascending = best matches first)
        # Using bubble sort O(n²) — acceptable for n≤20 (WIKI_GROUP_NAMES size)
        # Worst case: 20×19/2 = 190 comparisons — negligible for this use case
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
    } else {
        # Best-match mode: print idx:dist
        print best_idx ":" best_dist
    }
}
'
}

# AWK-based fuzzy matching — optimized for speed
# Uses Levenshtein distance with awk (single source of truth)
awk_fuzzy_match() {
    local query="$1"
    local groups="$2"

    # Limit query length to prevent DoS (use character count, not bytes)
    local query_len
    query_len="$(printf '%s' "$query" | wc -m)"
    query_len="${query_len//[[:space:]]/}"
    if [[ "$query_len" -gt 50 ]]; then
        query="$(printf '%s' "$query" | cut -c1-50)"
    fi

    # Sanitize: strip chars that can escape awk -v string context (", \, newline)
    # Defense-in-depth: caller may sanitize too, but awk injection happens HERE
    query="$(printf '%s' "$query" | tr -cd '[:alnum:]_ ')"

    if [[ -z "$query" ]]; then
        printf '%s\n' "-1:999"
        return 1
    fi

    # Use shared Levenshtein helper (single source of truth, mode=best)
    printf '%s\n' "$groups" | _wiki_awk "$query" "best"
}

# Find best match using awk fuzzy matching
find_wiki_group_awk() {
    local query="$1"

    # Normalize query: lowercase, trim whitespace, remove special chars (security)
    query="$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -cd '[:alnum:]_ ')"

    # Early exit for empty or invalid query
    if [[ -z "$query" || ${#query} -gt 50 ]]; then
        printf '%d\n' "-1"
        return 1
    fi

    # METHOD 1: Alias lookup
    if [[ -n "${WIKI_ALIASES[$query]:-}" ]]; then
        local target="${WIKI_ALIASES[$query]}"
        local i=0
        for group in "${WIKI_GROUP_NAMES[@]}"; do
            [[ "$group" == *"$target"* ]] && printf '%d\n' "$i" && return 0
            i=$((i+1))
        done
    fi

    # METHOD 2: Exact match
    local i=0
    for group in "${WIKI_GROUP_NAMES[@]}"; do
        [[ "$group" == *"$query"* ]] && printf '%d\n' "$i" && return 0
        i=$((i+1))
    done

    # METHOD 3: Fuzzy matching with awk
    local groups_str
    groups_str="$(printf '%s\n' "${WIKI_GROUP_NAMES[@]}")"
    local result
    result="$(awk_fuzzy_match "$query" "$groups_str")"

    # Parse result format: "index:distance" (e.g., "3:2")
    # Validate result is non-empty and has expected format before parsing
    if [[ -z "$result" || "$result" != *":"* ]]; then
        printf '%d\n' "-1"
        return 1
    fi

    local best_idx="${result%%:*}"
    local best_dist="${result##*:}"

    # Validate both values are numeric before comparison
    # Prevents bash error: empty string -ge 0 (integer expression expected)
    if [[ "$best_idx" =~ ^-?[0-9]+$ ]] && [[ "$best_dist" =~ ^[0-9]+$ ]]; then
        if [[ "$best_idx" -ge 0 && "$best_dist" -le 3 ]]; then
            printf '%d\n' "$best_idx" && return 0
        fi
    fi

    printf '%d\n' "-1"
    return 1
}

# Get suggestions using awk — uses shared Levenshtein helper
suggest_wiki_groups_awk() {
    local query="$1"

    # Convert to lowercase, trim whitespace, strip awk-dangerous chars (", \, newline)
    # tr -cd whitelist prevents awk injection via -v q="$query"
    query="$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -cd '[:alnum:]_ ')"

    # Early exit for empty or too long query
    if [[ -z "$query" || ${#query} -gt 50 ]]; then
        return 1
    fi

    local groups_str
    groups_str="$(printf '%s\n' "${WIKI_GROUP_NAMES[@]}")"

    # Use shared Levenshtein helper (single source of truth, mode=suggest)
    printf '%s\n' "$groups_str" | _wiki_awk "$query" "suggest"
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
    
    # Accept optional cached term_width to avoid repeated tput forks
    local term_width="${2:-}"
    if [[ -z "$term_width" ]]; then
        term_width="$(tput cols 2>/dev/null)" || term_width=80
    fi
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
        *)  # Invalid group index
            warn "show_wiki_group: invalid group index '$group_idx' (expected 0-$((${#WIKI_GROUP_NAMES[@]} - 1)))"
            return 1
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
        normalized_group="$(printf '%s\n' "$WIKI_GROUP" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

        # Check if numeric index (1-20) - direct lookup
        if [[ "$normalized_group" =~ ^[0-9]+$ ]]; then
            local group_idx=$((normalized_group - 1))
            if [[ "$group_idx" -ge 0 && "$group_idx" -lt "${#WIKI_GROUP_NAMES[@]}" ]]; then
                show_wiki_group "$group_idx"
                return 0
            fi
            # Out of range - fall through to error handling
        fi

        # Find matching group by keyword (use || true to prevent exit on no match due to set -e)
        local group_idx
        group_idx="$(find_wiki_group "$normalized_group" || true)"

        if [[ -n "$group_idx" && "$group_idx" =~ ^-?[0-9]+$ && "$group_idx" -ge 0 ]]; then
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
                printf '%s\n' "$suggestions" | while read -r sug_line; do
                    local cmd desc
                    cmd="$(printf '%s' "$sug_line" | awk '{print $1}')"
                    desc="$(printf '%s' "$sug_line" | cut -d' ' -f2-)"
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

    # No group specified - show all 20 groups by calling show_wiki_group for each
    # Cache terminal width once to avoid 20 tput forks
    local cached_width i
    cached_width="$(tput cols 2>/dev/null)" || cached_width=80
    for ((i = 0; i < ${#WIKI_GROUP_NAMES[@]}; i++)); do
        show_wiki_group "$i" "$cached_width"
    done
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
    - Scan modes are mutually exclusive; last flag takes precedence
      Example: --all --kernel runs kernel only (last flag wins)

EOF
}

# ─────────────────────────────────────────────────────────────────────────────

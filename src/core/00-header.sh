#!/usr/bin/env bash
# file: arch-diag.sh
# arlogkn - Read-only diagnostic tool
# Dependencies: bash 5.0+, coreutils, util-linux, systemd, awk, sed, grep

# Check bash version (require 5.0+ for declare -g and other features)
if (( BASH_VERSINFO[0] < 5 )); then
    printf '[ERROR] This script requires bash 5.0 or later (current: %s)\n' "$BASH_VERSION" >&2
    exit 1
fi

set -euo pipefail
shopt -s extglob  # Enable extglob at parse-time for +([[:space:]]) patterns

# ─────────────────────────────────────────────────────────────────────────────
# GLOBALS & CONFIG
# ─────────────────────────────────────────────────────────────────────────────
# VERSION is now dynamically injected by build.sh
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

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

# Caches to avoid redundant system calls
declare -g _DRIVERS_CACHE=""
declare -g _LSPCI_CACHE=""
declare -g _LSPCI_CACHE_INIT=0

# ─────────────────────────────────────────────────────────────────────────────

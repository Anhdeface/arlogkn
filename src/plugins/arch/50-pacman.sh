# shellcheck shell=bash
scan_pacman_logs() {
    draw_section_header "PACMAN / ALPM (Errors & Warnings)"

    # Early check: pacman is Arch-specific. Skip gracefully on non-Arch systems.
    # This prevents confusing "log not found" messages on Ubuntu, Fedora, etc.
    if [[ "$DISTRO_TYPE" != "Arch-based" && "$DISTRO_TYPE" != "Performance Tuned" && \
          "$DISTRO_NAME" != *"Arch"* && "$DISTRO_NAME" != *"CachyOS"* ]]; then
        draw_box_line "${C_YELLOW}Skipping pacman scan (non-Arch system)${C_RESET}"
        draw_box_line "${C_BLUE}Note: pacman is the package manager for Arch Linux${C_RESET}"
        return 0
    fi

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

    # Color-code based on severity using awk (case-insensitive via tolower())
    # Avoids pipeline subshell anti-pattern:
    # - 'local' in pipeline subshell is semantically wrong (no function scope)
    # - shopt nocasematch inheritance is fragile ("works by accident")
    # - Complex ERR trap handling to clean up nocasematch is unnecessary
    printf '%s\n' "$issues" | awk -v red="$C_RED" -v ylw="$C_YELLOW" -v rst="$C_RESET" '
    {
        # Sanitize: remove potential ANSI/binary garbage
        gsub(/[^[:print:]\t]/, "")
        line = $0
    }
    tolower(line) ~ /error/ {
        print red line rst
        next
    }
    tolower(line) ~ /warning/ {
        print ylw line rst
        next
    }
    { print line }
    ' | while read -r colored_line; do
        draw_box_line "$colored_line"
    done

}

# ─────────────────────────────────────────────────────────────────────────────
export_pacman_logs() {
    # Guard: validate OUTPUT_DIR
    if [[ -z "$OUTPUT_DIR" || ! -d "$OUTPUT_DIR" ]]; then
        warn "export_pacman_logs: OUTPUT_DIR not set or invalid"
        return 1
    fi

    # Early check: pacman is Arch-specific. Skip gracefully on non-Arch systems.
    if [[ "$DISTRO_TYPE" != "Arch-based" && "$DISTRO_TYPE" != "Performance Tuned" && \
          "$DISTRO_NAME" != *"Arch"* && "$DISTRO_NAME" != *"CachyOS"* ]]; then
        printf 'Skipping pacman export (non-Arch system)\n' > "${OUTPUT_DIR}/pacman_errors.txt"
        info "Pacman export skipped (non-Arch system)"
        return 0
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


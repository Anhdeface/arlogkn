# shellcheck shell=bash
# MAIN ENTRY POINT
# ─────────────────────────────────────────────────────────────────────────────

# Helper: Export individual components based on scan scope
# Prevents DRY violation between SCAN_ALL and SCAN_SYSTEM branches
_export_components() {
    local is_full_scan="$1"
    local export_failed=0

    # These logs are only exported during a full scan
    if [[ "$is_full_scan" -eq 1 ]]; then
        export_kernel_logs || { warn "Export kernel logs failed"; export_failed=1; }
        export_user_services || { warn "Export user services failed"; export_failed=1; }
        export_coredumps || { warn "Export coredumps failed"; export_failed=1; }
        
        if [[ "$(type -t export_pacman_logs)" == "function" && "${_DISABLE_PLUGINS:-0}" -eq 0 ]]; then
            export_pacman_logs || { warn "Export pacman logs failed"; export_failed=1; }
        fi
    fi

    # Hardware & system details exported by both scans
    export_mounts || { warn "Export mounts failed"; export_failed=1; }
    export_usb_devices || { warn "Export USB devices failed"; export_failed=1; }
    export_vga_info || { warn "Export VGA info failed"; export_failed=1; }
    export_drivers || { warn "Export drivers failed"; export_failed=1; }
    export_temperatures || { warn "Export temperatures failed"; export_failed=1; }
    export_boot_timing || { warn "Export boot timing failed"; export_failed=1; }
    export_network_interfaces || { warn "Export network interfaces failed"; export_failed=1; }
    export_summary || { warn "Export summary failed"; export_failed=1; }

    return "$export_failed"
}

main() {
    init_colors
    parse_args "$@"

    # Wiki mode: skip all system detection, just show wiki and exit
    if [[ "$SCAN_WIKI" -eq 1 ]]; then
        show_wiki
        return 0
    fi

    # Validate conflicting export flags
    if [[ "$SAVE_LOGS" -eq 1 && "$SAVE_ALL" -eq 1 ]]; then
        warn "Conflicting export modes detected (--save and --save-all)"
        warn "Using --save-all (single file export), ignoring --save"
        SAVE_LOGS=0  # Clear conflicting flag
    fi

    detect_distro
    detect_system_info
    detect_network_status || true
    detect_gpu
    detect_display

    # Graceful Degradation: Check if compiled target matches runtime OS
    if [[ "${_COMPILED_TARGET:-universal}" != "universal" ]]; then
        if [[ "$_COMPILED_TARGET" == "arch" ]]; then
            if [[ "$DISTRO_TYPE" != "Arch-based" && "$DISTRO_NAME" != *"Arch"* && "$DISTRO_NAME" != *"CachyOS"* ]]; then
                warn "This script was compiled for Arch Linux, but you are running on ${DISTRO_NAME}."
                warn "Arch-specific modules will be disabled to ensure stability."
                _DISABLE_PLUGINS=1
            fi
        fi
    fi

    local width=70

    # Header
    printf '\n'
    draw_header "ARLOGKN v${VERSION}"
    printf '\n'
    draw_info_box "System" "${DISTRO_NAME} (${DISTRO_TYPE})"
    draw_info_box "Kernel" "${KERNEL_VER}"
    draw_info_box "CPU Governor" "${CPU_GOVERNOR}"

    # Network status (not internet — having IP ≠ internet access)
    case "$INTERNET_STATUS" in
        "connected")
            draw_info_box "Network" "${C_GREEN}Connected${C_RESET}"
            ;;
        "ip_assigned")
            draw_info_box "Network" "${C_YELLOW}IP Assigned (unverified)${C_RESET}"
            ;;
        "link_up")
            draw_info_box "Network" "${C_YELLOW}Link Up (no IP)${C_RESET}"
            ;;
        *)
            draw_info_box "Network" "${C_RED}Disconnected${C_RESET}"
            ;;
    esac

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
        
        if [[ "$(type -t scan_pacman_logs)" == "function" && "${_DISABLE_PLUGINS:-0}" -eq 0 ]]; then
            scan_pacman_logs
        fi
        
        scan_mounts
        scan_usb_devices
        scan_network_interfaces

        # Export logs if --save is set (separate files)
        if [[ "$SAVE_LOGS" -eq 1 ]]; then
            printf '\n'
            draw_box_line "${C_CYAN}Exporting logs to ${OUTPUT_DIR}...${C_RESET}"
            
            if _export_components 1; then
                draw_box_line "${C_GREEN}✓ Export complete: ${OUTPUT_DIR}${C_RESET}"
            else
                draw_box_line "${C_YELLOW}⚠ Some exports failed (check warnings above)${C_RESET}"
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
        [[ "$SCAN_DRIVER" -eq 1 ]] && warn "Flag --driver is redundant and ignored (included in --all)"
        [[ "$SCAN_VGA" -eq 1 ]]    && warn "Flag --vga is redundant and ignored (included in --all)"
        [[ "$SCAN_KERNEL" -eq 1 ]] && warn "Flag --kernel is redundant and ignored (included in --all)"
        [[ "$SCAN_USER" -eq 1 ]]   && warn "Flag --user is redundant and ignored (included in --all)"
        [[ "$SCAN_MOUNT" -eq 1 ]]  && warn "Flag --mount is redundant and ignored (included in --all)"
        [[ "$SCAN_USB" -eq 1 ]]    && warn "Flag --usb is redundant and ignored (included in --all)"
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
            
            if _export_components 0; then
                draw_box_line "${C_GREEN}✓ Export complete: ${OUTPUT_DIR}${C_RESET}"
            else
                draw_box_line "${C_YELLOW}⚠ Some exports failed (check warnings above)${C_RESET}"
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
        # SCAN_SYSTEM calls: scan_vga_info, scan_drivers, scan_mounts, scan_usb_devices
        # SCAN_SYSTEM does NOT call: scan_kernel_logs, scan_user_services (coredumps)
        # So we only clear flags that would cause double execution
        [[ "$SCAN_DRIVER" -eq 1 ]] && warn "Flag --driver is redundant and ignored (included in --system)"
        [[ "$SCAN_VGA" -eq 1 ]]    && warn "Flag --vga is redundant and ignored (included in --system)"
        [[ "$SCAN_MOUNT" -eq 1 ]]  && warn "Flag --mount is redundant and ignored (included in --system)"
        [[ "$SCAN_USB" -eq 1 ]]    && warn "Flag --usb is redundant and ignored (included in --system)"
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

# shellcheck shell=bash
# HWV2: Advanced Hardware Detection Plugin
# ─────────────────────────────────────────────────────────────────────────────

scan_storage_v2() {
    draw_section_header "STORAGE DEVICES (HWV2)"
    printf '\n'
    
    # Pre-cache /proc/mounts to match against partitions efficiently
    # key: device path, value: mount point
    local -A mounts_map
    local source target fstype
    while IFS=' ' read -r source target fstype _rest; do
        if [[ "$source" == /dev/* ]]; then
            # Decode octal escapes
            target="${target//\\040/ }"
            target="${target//\\011/$'\t'}"
            target="${target//\\134/\\}"
            mounts_map["$source"]="$target"
        fi
    done < /proc/mounts 2>/dev/null || true

    # Prepare nullglob safely
    local _ng_was_set=0
    shopt -q nullglob && _ng_was_set=1
    local _old_ret_trap
    _old_ret_trap="$(trap -p RETURN)"
    shopt -s nullglob
    # shellcheck disable=SC2064
    trap "$(if [[ $_ng_was_set -eq 0 ]]; then echo 'shopt -u nullglob;'; else echo ':;'; fi) ${_old_ret_trap:-trap - RETURN}" RETURN

    local found=0

    for block_dir in /sys/block/*; do
        [[ -L "$block_dir" && ! -e "$block_dir" ]] && continue
        [[ ! -d "$block_dir" ]] && continue

        local bname
        bname="${block_dir##*/}"
        
        # Helper to read file safely
        _read_sys() {
            local file="$1"
            if [[ -f "$file" && -r "$file" ]]; then
                cat "$file" 2>/dev/null | tr -d '\000' | head -n1 || echo ""
            else
                echo ""
            fi
        }

        # Only process physical-like devices (sd*, nvme*, mmcblk*)
        if [[ ! "$bname" =~ ^(sd[a-z]+|nvme[0-9]+n[0-9]+|mmcblk[0-9]+)$ ]]; then
            continue
        fi

        found=1
        local size_sectors size_gb model vendor removable type_str color
        
        # Determine basic type
        removable="$(_read_sys "$block_dir/removable")"
        [[ -z "$removable" ]] && removable="0"
        
        if [[ "$bname" == nvme* ]]; then
            type_str="NVMe"
            color="$C_GREEN"
        elif [[ "$bname" == mmc* ]]; then
            type_str="eMMC/SD"
            color="$C_YELLOW"
        else
            if [[ "$removable" == "1" ]]; then
                type_str="USB"
                color="$C_CYAN"
            else
                type_str="SATA"
                color="$C_BLUE"
            fi
        fi

        size_sectors="$(_read_sys "$block_dir/size")"
        [[ -z "$size_sectors" ]] && size_sectors=0
        size_gb=$(( size_sectors * 512 / 1073741824 ))

        vendor="$(_read_sys "$block_dir/device/vendor")"
        model="$(_read_sys "$block_dir/device/model")"
        
        local full_model="${vendor} ${model}"
        # trim spaces
        full_model="${full_model#"${full_model%%[![:space:]]*}"}"
        full_model="${full_model%"${full_model##*[![:space:]]}"}"
        [[ -z "$full_model" ]] && full_model="Unknown Device"

        draw_box_line "├─ ${color}${bname}${C_RESET} [${type_str}] ${size_gb}GB - ${full_model}"

        # Find partitions
        local part_count=0
        local -a partitions=()
        for part_dir in "$block_dir"/${bname}*; do
            [[ -d "$part_dir" ]] && partitions+=("$part_dir")
        done
        
        # Sort partitions to ensure proper order (e.g. sda1, sda2)
        IFS=$'\n' read -d '' -r -a partitions < <(printf '%s\n' "${partitions[@]}" | sort -V) || true

        for part_dir in "${partitions[@]}"; do
            local pname
            pname="${part_dir##*/}"
            local psize_sect psize_mb psize_str ptarget
            psize_sect="$(_read_sys "$part_dir/size")"
            [[ -z "$psize_sect" ]] && psize_sect=0
            psize_mb=$(( psize_sect * 512 / 1048576 ))
            
            if [[ $psize_mb -ge 1024 ]]; then
                psize_str="$(( psize_mb / 1024 ))GB"
            else
                psize_str="${psize_mb}MB"
            fi

            ptarget="${mounts_map["/dev/$pname"]:-}"
            if [[ -n "$ptarget" ]]; then
                draw_box_line "│  └─ /dev/${pname} (${psize_str}) ➞ mounted on ${C_CYAN}${ptarget}${C_RESET}"
            else
                draw_box_line "│  └─ /dev/${pname} (${psize_str})"
            fi
        done
        draw_box_line "│"
    done
    
    if [[ "$found" -eq 0 ]]; then
        draw_box_line "${C_YELLOW}No storage devices found.${C_RESET}"
    fi

    printf '\n'
}

scan_peripherals_v2() {
    draw_section_header "PERIPHERALS (HWV2)"
    printf '\n'
    
    local _ng_was_set=0
    shopt -q nullglob && _ng_was_set=1
    local _old_ret_trap
    _old_ret_trap="$(trap -p RETURN)"
    shopt -s nullglob
    # shellcheck disable=SC2064
    trap "$(if [[ $_ng_was_set -eq 0 ]]; then echo 'shopt -u nullglob;'; else echo ':;'; fi) ${_old_ret_trap:-trap - RETURN}" RETURN

    # Helper to read file safely
    _read_sys() {
        local file="$1"
        if [[ -f "$file" && -r "$file" ]]; then
            cat "$file" 2>/dev/null | tr -d '\000' | head -n1 || echo ""
        else
            echo ""
        fi
    }

    # 1. USB Devices Tree
    draw_box_line "${C_CYAN}USB Subsystem Tree:${C_RESET}"
    if [[ -d /sys/bus/usb/devices ]]; then
        local usb_found=0
        for dev_path in /sys/bus/usb/devices/*; do
            [[ -L "$dev_path" && ! -e "$dev_path" ]] && continue
            [[ ! -d "$dev_path" ]] && continue
            
            local dev_name
            dev_name="${dev_path##*/}"
            [[ "$dev_name" == usb* ]] && continue
            [[ ! -f "$dev_path/idVendor" ]] && continue

            usb_found=1
            local vendor product speed driver
            vendor="$(_read_sys "$dev_path/idVendor")"
            product="$(_read_sys "$dev_path/product")"
            [[ -z "$product" ]] && product="$(_read_sys "$dev_path/manufacturer")"
            [[ -z "$product" ]] && product="Unknown USB Device"
            
            speed="$(_read_sys "$dev_path/speed")"
            [[ -z "$speed" ]] && speed="?"
            
            # Sanitize product string using parameter expansion and safe bash replacements where possible
            # Here we fallback to sed/tr for ANSI cleanup because bash pattern replacement for ANSI is extremely complex
            product="$(printf '%s' "$product" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '[:cntrl:]')"
            
            # Find driver mapped to interface 0
            driver=""
            if [[ -d "$dev_path/${dev_name}:1.0/driver" ]]; then
                driver="$(basename "$(readlink -f "$dev_path/${dev_name}:1.0/driver" 2>/dev/null)" 2>/dev/null)" || driver=""
            fi
            
            local drv_str=""
            [[ -n "$driver" ]] && drv_str=" (drv: ${C_GREEN}${driver}${C_RESET})"

            draw_box_line "  ├─ Bus/Dev ${dev_name}: ${product} [${speed} Mbps]${drv_str}"
        done
        [[ "$usb_found" -eq 0 ]] && draw_box_line "  └─ No external USB devices found"
    else
        draw_box_line "  └─ USB Subsystem not available"
    fi
    printf '\n'

    # 2. Audio Devices
    draw_box_line "${C_CYAN}Audio Subsystem:${C_RESET}"
    local audio_found=0
    for card_path in /sys/class/sound/card*; do
        [[ ! -d "$card_path" ]] && continue
        
        local card_id
        card_id="$(_read_sys "$card_path/id")"
        [[ -z "$card_id" ]] && card_id="Unknown"
        
        local card_drv=""
        if [[ -d "$card_path/device/driver" ]]; then
            card_drv="$(basename "$(readlink -f "$card_path/device/driver" 2>/dev/null)" 2>/dev/null)" || card_drv=""
        fi
        
        local name_str=""
        if [[ -f "$card_path/device/uevent" ]]; then
            # extract model name if present
            while IFS='=' read -r key val; do
                if [[ "$key" == "OF_NAME" || "$key" == "PCI_SLOT_NAME" ]]; then
                    name_str="[$val]"
                    break
                fi
            done < "$card_path/device/uevent"
        fi

        local drv_disp=""
        [[ -n "$card_drv" ]] && drv_disp=" (drv: ${C_GREEN}${card_drv}${C_RESET})"
        
        draw_box_line "  ├─ Card: ${card_id:-Unknown} ${name_str}${drv_disp}"
        audio_found=1
    done
    if [[ "$audio_found" -eq 0 ]]; then
        draw_box_line "  └─ No audio devices detected"
    fi
    printf '\n'
}

export_storage_v2() {
    export_start "storage_v2.txt"
    local _ng_was_set=0
    shopt -q nullglob && _ng_was_set=1
    local _old_ret_trap
    _old_ret_trap="$(trap -p RETURN)"
    shopt -s nullglob
    # shellcheck disable=SC2064
    trap "$(if [[ $_ng_was_set -eq 0 ]]; then echo 'shopt -u nullglob;'; else echo ':;'; fi) ${_old_ret_trap:-trap - RETURN}" RETURN

    for d in /sys/block/*; do
        [[ -d "$d" ]] || continue
        echo "Device: ${d##*/}" >> "$EXPORT_FILE"
        if [[ -f "$d/size" ]]; then
            local s
            s="$(cat "$d/size" 2>/dev/null || true)"
            [[ -n "$s" ]] && echo "  Size: $s sectors" >> "$EXPORT_FILE"
        fi
        if [[ -f "$d/device/model" ]]; then
            local m
            m="$(cat "$d/device/model" 2>/dev/null || true)"
            [[ -n "$m" ]] && echo "  Model: $m" >> "$EXPORT_FILE"
        fi
        for p in "$d"/${d##*/}*; do
            [[ -d "$p" ]] || continue
            echo "  Partition: ${p##*/}" >> "$EXPORT_FILE"
            if [[ -f "$p/size" ]]; then
                local ps
                ps="$(cat "$p/size" 2>/dev/null || true)"
                [[ -n "$ps" ]] && echo "    Size: $ps sectors" >> "$EXPORT_FILE"
            fi
        done
    done
    export_end "storage_v2.txt"
}

export_peripherals_v2() {
    export_start "peripherals_v2.txt"
    local _ng_was_set=0
    shopt -q nullglob && _ng_was_set=1
    local _old_ret_trap
    _old_ret_trap="$(trap -p RETURN)"
    shopt -s nullglob
    # shellcheck disable=SC2064
    trap "$(if [[ $_ng_was_set -eq 0 ]]; then echo 'shopt -u nullglob;'; else echo ':;'; fi) ${_old_ret_trap:-trap - RETURN}" RETURN

    if [[ -d /sys/bus/usb/devices ]]; then
        for d in /sys/bus/usb/devices/*; do
            [[ -d "$d" ]] || continue
            [[ ! -f "$d/idVendor" ]] && continue
            echo "USB: ${d##*/}" >> "$EXPORT_FILE"
            if [[ -f "$d/idVendor" ]]; then
                local v
                v="$(cat "$d/idVendor" 2>/dev/null || true)"
                [[ -n "$v" ]] && echo "  Vendor: $v" >> "$EXPORT_FILE"
            fi
            if [[ -f "$d/idProduct" ]]; then
                local pr
                pr="$(cat "$d/idProduct" 2>/dev/null || true)"
                [[ -n "$pr" ]] && echo "  Product: $pr" >> "$EXPORT_FILE"
            fi
            if [[ -f "$d/product" ]]; then
                local nm
                nm="$(cat "$d/product" 2>/dev/null || true)"
                [[ -n "$nm" ]] && echo "  Name: $nm" >> "$EXPORT_FILE"
            fi
        done
    fi
    export_end "peripherals_v2.txt"
}

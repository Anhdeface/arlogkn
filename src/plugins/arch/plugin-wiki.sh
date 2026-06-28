# shellcheck shell=bash

# Register Arch Linux specific wiki groups
WIKI_GROUP_NAMES+=(
    "pacman package management"
    "aur helpers yay paru"
    "arch utilities"
)

WIKI_GROUP_KEYS+=(
    "pacman"
    "aur"
    "archutil"
)

# Register corresponding aliases
WIKI_ALIASES["pkg"]="pacman"

show_wiki_group_pacman() {
    local col1_width="${1:-35}"
    local col2_width=$(( col1_width - 5 ))
    
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
}

show_wiki_group_aur() {
    local col1_width="${1:-35}"
    local col2_width=$(( col1_width - 5 ))
    
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
}

show_wiki_group_archutil() {
    local col1_width="${1:-35}"
    local col2_width=$(( col1_width - 5 ))
    
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
}

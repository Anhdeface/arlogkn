# arlogkn

**Version:** 1.0.0 | **Platform:** Arch Linux and derivatives

Read-only system diagnostic tool for analyzing logs, checking hardware, and exporting reports.

## Requirements

- **OS:** Arch Linux, CachyOS, Manjaro, EndeavourOS
- **Dependencies:** bash 5.0+, coreutils, util-linux, systemd, awk, sed, grep
- **Permissions:** Root recommended for full log access

## Usage

```bash
./arch-diag.sh                    # Full system scan
./arch-diag.sh --kernel           # Kernel errors only
./arch-diag.sh --kernel --boot=-1 # Previous boot errors
./arch-diag.sh --save             # Export to separate files
./arch-diag.sh --save-all         # Export to single file
./arch-diag.sh --wiki             # Command reference
./arch-diag.sh --wiki=sound       # Specific group (20 groups available)
```

## Options

| Option | Description |
|--------|-------------|
| `--all` | Full scan (default) |
| `--kernel` | Kernel log scan |
| `--user` | User service scan |
| `--mount` | Filesystem scan |
| `--usb` | USB device scan |
| `--driver` | Driver status |
| `--vga` | GPU/Display info |
| `--system` | System scan (no logs) |
| `--wiki` | Command reference |
| `--wiki=<group>` | Specific group |
| `--boot=N` | Boot number (0=current, -1=previous) |
| `--save` | Export separate files |
| `--save-all` | Export single file |
| `--help, -h` | Show help |
| `--version, -v` | Show version |

## Output

- **Direct:** Terminal output with colors
- **Export:** `./arch-diag-logs/YYYYMMDD_HHMMSS/`
- **Files:** kernel_errors.txt, service_errors.txt, coredumps.txt, pacman_errors.txt, mounts.txt, usb_devices.txt, vga_info.txt, drivers.txt, summary.txt

## Notes

- **Read-only:** No system modifications
- **Root access:** Recommended for full log visibility
- **Wiki notes:** `(package)` or `(AUR)` suffixes indicate required installations
- **Fuzzy matching:** Wiki suggests corrections for typos (e.g., `soud` → `sound`)

## Troubleshooting

```bash
sudo ./arch-diag.sh    # Permission denied
df -h .                # Check disk space
```

https://wiki.archlinux.org

# arlogkn

**Version:** 1.0.1 | **Platform:** Arch Linux and derivatives

A read-only system diagnostic and log extraction utility designed for Arch Linux. It performs comprehensive hardware and software state analysis without requiring external dependencies, ensuring safety and reliability on broken or minimal systems.

## Design Philosophy & Advantages

- **Zero External Dependencies**: Operates entirely on standard tools (`bash` 5.0+, `coreutils`, `util-linux`, `systemd`) and low-level pseudo-filesystems (`/sys`, `/proc`). It does not require any additional package installations (`inxi`, `hwinfo`, etc.), making it ideal for diagnosing network-isolated or severely broken systems.
- **Strictly Read-Only Analysis**: The script is hardcoded to never alter system state, modify configurations, or execute state-changing binaries. It is completely safe to run in critical production or recovery environments.
- **Arch-Native & Systemd-Optimized**: Tailored specifically for the Arch ecosystem. It natively parses `pacman` logs, integrates deeply with `journalctl` for kernel/service errors, extracts failing `systemctl` units, profiles boot performance via `systemd-analyze`, and traces crashes via `coredumpctl`.

## Requirements

- **OS:** Arch Linux, CachyOS, Manjaro, EndeavourOS (or generic systemd-based Linux systems)
- **Core Dependencies:** `bash`, `coreutils`, `util-linux`, `systemd`, `awk`, `sed`, `grep`
- **Permissions:** Root access (`sudo`) is highly recommended to ensure complete visibility into hardware subsystems and protected system logs.

## Usage

```bash
./arch-diag.sh                    # Execute full system diagnostic scan
./arch-diag.sh --kernel           # Isolate and report kernel errors only
./arch-diag.sh --kernel --boot=-1 # Isolate kernel errors from the previous boot
./arch-diag.sh --save             # Export diagnostics into categorized text files
./arch-diag.sh --save-all         # Export full diagnostics into a single unified file
./arch-diag.sh --wiki             # Access the interactive Arch Wiki command reference
./arch-diag.sh --wiki=sound       # Query specific wiki subsystem (e.g., sound, network)
```

## Options

| Option | Description |
|--------|-------------|
| `--all` | Execute comprehensive full system scan (default behavior). |
| `--kernel` | Execute kernel log and ring buffer analysis. |
| `--user` | Execute user service analysis and unit failure scan. |
| `--mount` | Execute filesystem mount point scan. |
| `--usb` | Execute connected USB device taxonomy scan. |
| `--driver` | Execute kernel module and driver attachment scan. |
| `--vga` | Execute GPU, DRM, and display bridge scan. |
| `--system` | Execute core system hardware scan (bypasses system logs). |
| `--wiki` | Launch offline command and troubleshooting reference. |
| `--wiki=<group>` | Query a specific troubleshooting group (fuzzy matching enabled). |
| `--boot=N` | Specify journalctl boot offset (`0`=current, `-1`=previous, etc.). |
| `--save` | Export diagnostic output into separate categorized files. |
| `--save-all` | Export all diagnostic output into a single consolidated file. |
| `--help, -h` | Print manual page. |
| `--version, -v` | Print version information. |

## Output Management

- **Direct Interface:** Standard terminal output with conditional ANSI formatting.
- **Export Directory:** `./arch-diag-logs/YYYYMMDD_HHMMSS/`
- **Generated Artifacts:** `kernel_errors.txt`, `service_errors.txt`, `coredumps.txt`, `pacman_errors.txt`, `mounts.txt`, `usb_devices.txt`, `vga_info.txt`, `drivers.txt`, `temperatures.txt`, `boot_timing.txt`, `network_interfaces.txt`, `summary.txt`

## Technical Notes

- Data extracted from `/sys/class/drm` and `/sys/class/net` bypasses the need for `xrandr` and `iproute2` parsing where possible.
- Missing dependencies are silently handled via `command -v` checks or `|| true` fallbacks to ensure uninterrupted execution.
- Wiki search natively performs dynamic fuzzy-matching to accommodate typographical errors during CLI usage.

## Troubleshooting

```bash
sudo ./arch-diag.sh    # Address 'Permission denied' when accessing /var/log/pacman.log or /sys structures.
df -h .                # Address incomplete exports resulting from local storage exhaustion.
```

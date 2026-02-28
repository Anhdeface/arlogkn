# arlogkn

**Version:** 1.0.3 | **Platform:** Arch Linux and derivatives | **License:** MIT | **![Report VirusTotal](https://www.virustotal.com/gui/file/33b074d65643a15a9f703c3333006dd271b65fadec8dff198e7796fb6484ae1c/detection)**


A read-only system diagnostic and log extraction utility for Arch Linux. Performs comprehensive hardware and software state analysis without external dependencies, ensuring safety and reliability on broken or minimal systems.
---

## Quick Start

```bash
# Full system diagnostic scan (default)
./arch-diag.sh

# Check kernel errors from previous boot
./arch-diag.sh --kernel --boot=-1

# Export all diagnostics to a single file
./arch-diag.sh --save-all
```

---

## What It Does

arlogkn inspects your system's current state and extracts diagnostic information from:

- **Kernel logs** - Errors from the kernel ring buffer (journalctl -k)
- **System services** - Failed units and service journal errors
- **Hardware state** - GPU, drivers, temperatures, USB devices, network interfaces
- **Boot performance** - systemd-analyze blame and timing
- **Package logs** - pacman errors and warnings
- **Crash dumps** - coredumpctl entries

All data is **read-only**. The script never modifies system state, configurations, or executes state-changing binaries.

---

## Design Philosophy

### Zero External Dependencies
Operates entirely on standard tools (`bash` 5.0+, `coreutils`, `util-linux`, `systemd`) and low-level pseudo-filesystems (`/sys`, `/proc`). No additional packages (`inxi`, `hwinfo`, etc.) required. Ideal for diagnosing network-isolated or severely broken systems.

### Strictly Read-Only
Hardcoded to never alter system state. Safe to run in critical production or recovery environments.

### Arch-Native & Systemd-Optimized
Tailored for the Arch ecosystem. Native `pacman` log parsing, deep `journalctl` integration, failing `systemctl` unit extraction, boot profiling via `systemd-analyze`, and crash tracing via `coredumpctl`.

---

## Requirements

| Category | Details |
|----------|---------|
| **OS** | Arch Linux, CachyOS, Manjaro, EndeavourOS (or generic systemd-based Linux) |
| **Shell** | `bash` 5.0+ |
| **Core utilities** | `coreutils`, `util-linux`, `systemd`, `awk`, `sed`, `grep` |
| **Permissions** | Root (`sudo`) recommended for full visibility into `/var/log`, `/sys`, and protected logs |

---

## Installation

No installation required. The script is standalone:

```bash
# Clone or download
git clone <repository-url>
cd arlogkn

# Make executable
chmod +x arch-diag.sh

# Run
./arch-diag.sh
```

---

## Usage

### Quick Reference

| Command | Purpose |
|---------|---------|
| `./arch-diag.sh` | Full system scan |
| `./arch-diag.sh --kernel` | Kernel errors only |
| `./arch-diag.sh --kernel --boot=-1` | Previous boot kernel errors |
| `./arch-diag.sh --system` | Hardware scan (no logs) |
| `./arch-diag.sh --save` | Export to separate files |
| `./arch-diag.sh --save-all` | Export to single file |
| `./arch-diag.sh --wiki` | Arch Wiki command reference |
| `./arch-diag.sh --wiki=sound` | Specific wiki group |

### Scan Modes

```bash
# Default: comprehensive scan
./arch-diag.sh --all

# Individual components
./arch-diag.sh --kernel      # Kernel ring buffer errors
./arch-diag.sh --user        # Service failures and coredumps
./arch-diag.sh --driver      # Kernel driver status
./arch-diag.sh --vga         # GPU and display info
./arch-diag.sh --mount       # Filesystems and disk usage
./arch-diag.sh --usb         # USB devices and storage
./arch-diag.sh --system      # Hardware overview (no logs)

# Combined scans
./arch-diag.sh --driver --vga           # GPU + driver status
./arch-diag.sh --kernel --boot=-1       # Previous boot errors
./arch-diag.sh --kernel --user --save   # Logs + export
```

### Export Modes

| Mode | Output | Use Case |
|------|--------|----------|
| `--save` | Separate files in `./arch-diag-logs/YYYYMMDD_HHMMSS/` | Targeted analysis, smaller files |
| `--save-all` | Single file `arch-log-inspector-all.txt` | Full snapshot, sharing, archiving |

**Example:**
```bash
# Export kernel errors, service errors, coredumps, etc. to separate files
./arch-diag.sh --save

# Export everything to one consolidated file
./arch-diag.sh --save-all
```

### Wiki Mode

Interactive Arch Wiki command reference with 20 topic groups and fuzzy matching:

```bash
# Show all wiki groups
./arch-diag.sh --wiki

# Query specific group (fuzzy matching enabled)
./arch-diag.sh --wiki=sound
./arch-diag.sh --wiki=graphics
./arch-diag.sh --wiki=boot
./arch-diag.sh --wiki=pacman
./arch-diag.sh --wiki=network
./arch-diag.sh --wiki=troubleshooting
```

**Supported groups:**
```
pacman, aur, system, process, hardware, disk, network, user, logs,
arch, performance, backup, troubleshooting, boot, memory, graphics,
sound, systemd, file, emergency
```

**Fuzzy matching examples:**
```bash
./arch-diag.sh --wiki=soud      # → suggests "sound"
./arch-diag.sh --wiki=netwok    # → suggests "network"
./arch-diag.sh --wiki=grafix    # → suggests "graphics"
```

---

## Options

| Option | Description |
|--------|-------------|
| `--all` | Comprehensive full system scan (default) |
| `--kernel` | Kernel log and ring buffer analysis |
| `--user` | User service analysis and unit failure scan |
| `--mount` | Filesystem mount point and disk usage scan |
| `--usb` | USB device taxonomy and storage scan |
| `--driver` | Kernel module and driver attachment scan |
| `--vga` | GPU, DRM, and display information |
| `--system` | Core system hardware scan (bypasses logs) |
| `--wiki` | Launch offline Arch Wiki command reference |
| `--wiki=<group>` | Query specific group (fuzzy matching enabled) |
| `--boot=N` | Journalctl boot offset (`0`=current, `-1`=previous) |
| `--save` | Export to separate categorized files |
| `--save-all` | Export to single consolidated file |
| `--help, -h` | Print help and exit |
| `--version, -v` | Print version and exit |

---

## Scan Capabilities

| Module | Data Source | Output |
|--------|-------------|--------|
| **Kernel Errors** | `journalctl -k -p 3` | Clustered error messages with boot context |
| **Service Errors** | `systemctl --failed`, `journalctl -u *.service` | Failed units, journal errors |
| **Core Dumps** | `coredumpctl list` | Last 5 crash entries |
| **Pacman Logs** | `/var/log/pacman.log` | Errors and warnings (last 100 lines) |
| **GPU / VGA** | `/sys/class/drm`, `lspci` | Graphics card, display, OpenGL info |
| **Drivers** | `/sys/class`, `lspci -k`, `lsmod` | GPU, network, audio, storage, USB, platform drivers |
| **Temperatures** | `/sys/class/hwmon` | Sensor readings with color thresholds |
| **Boot Timing** | `systemd-analyze`, `systemd-analyze blame` | Boot time, top 10 slowest services |
| **Network** | `/sys/class/net`, `ip` | Interface state, speed, MAC, IP |
| **Mounts** | `/proc/mounts`, `df` | Filesystem table, disk usage |
| **USB Devices** | `/sys/bus/usb/devices` | Device list, USB storage |
| **System Info** | `/proc/cpuinfo`, `/proc/swaps`, `uptime` | CPU, RAM, swap, uptime |

---

## Output Format

### Table Format
Clean, borderless tables with ANSI color coding:

```
 Interface      State    Speed      IP                   MAC
────────────────────────────────────────────────────────────────
 enp1s0         up       1Gbps      192.168.1.100        aa:bb:cc:dd:ee:ff
 wlp2s0         down     N/A        N/A                  11:22:33:44:55:66
```

### Box Drawing
Section headers and info boxes:

```
──[ KERNEL CRITICAL ]────────────────────────────────────────────

 ✓ No Critical Issues Found

──[ SYSTEM SERVICES ]────────────────────────────────────────────

 ✓ No failed services

 Service Errors (journalctl):
 ────────────────────────────────────────────────────────────────
 ✓ No Critical Issues Found
```

### Color Coding

| Color | Meaning |
|-------|---------|
| 🟢 Green | Normal / OK / Active |
| 🟡 Yellow | Warning / Degraded / Moderate threshold |
| 🔴 Red | Error / Failed / Critical threshold |
| 🔵 Blue | Info / Neutral |
| 🟣 Cyan | Highlight / Secondary info |

**Thresholds:**
- **Temperatures:** Green (<60°C), Yellow (60-80°C), Red (>80°C)
- **Disk usage:** Green (<70%), Yellow (70-90%), Red (>90%)
- **Boot time:** Green (<5s), Yellow (5-10s), Red (>10s)

---

## Output Management

### Export Directory
```
./arch-diag-logs/YYYYMMDD_HHMMSS/
```

### Generated Artifacts (--save mode)

| File | Content |
|------|---------|
| `kernel_errors.txt` | Kernel ring buffer errors |
| `kernel_errors_clustered.txt` | Deduplicated kernel errors |
| `service_errors.txt` | Service journal errors |
| `coredumps.txt` | Core dump list |
| `pacman_errors.txt` | Pacman errors and warnings |
| `mounts.txt` | Mounted filesystems and disk usage |
| `usb_devices.txt` | USB device list |
| `vga_info.txt` | GPU and display information |
| `drivers.txt` | Driver status |
| `temperatures.txt` | Hardware temperature readings |
| `boot_timing.txt` | Boot performance analysis |
| `network_interfaces.txt` | Network interface status |
| `summary.txt` | System overview and scan metadata |

### Single File Export (--save-all mode)
```
./arch-diag-logs/YYYYMMDD_HHMMSS/arch-log-inspector-all.txt
```
Contains all 13 sections above in a single consolidated file (raw format, no ANSI codes).

---

## Technical Architecture

### Caching Strategy
Avoids redundant system calls within a session:

```bash
_get_lspci()        # Caches `lspci -k` output (single call per session)
_get_lspci_knn()    # Caches `lspci -knn` output (for export)
_DRIVERS_CACHE      # Caches multi-source driver detection result
```

### Multi-Source Driver Detection
Drivers are detected from multiple sources in priority order:

1. **`/sys/class`** - Most reliable (DRM, net, sound, input, watchdog)
2. **`lspci -k`** - PCI device driver binding
3. **`/sys/bus/pci/drivers`** - Virtual drivers (virtio, vmware, xen)
4. **`lsmod`** - Module category detection (RAID, SATA, I2C)

### Error Clustering
Identical errors are grouped and counted:

```bash
cluster_errors() {
    # Normalize timestamps, count duplicates
    # Output: "Error message (x15)" instead of 15 identical lines
}
```

### ANSI-Aware String Handling
Table rendering correctly handles ANSI color codes:

```bash
strip_ansi()     # O(n) sed-based stripping (avoided O(n²) bash loop)
visible_len()    # Computes visible string length (excluding ANSI)
```

---

## Performance & Optimization

### Optimization Summary (28 Phases, 67 Improvements)

| Category | Count | Examples |
|----------|-------|----------|
| **Bug Fixes** | 52 | Off-by-one errors, trap handling, dispatch regression, symlink resolution |
| **Features** | 5 | Temperature scanning, boot timing, network interfaces, swap/zram status |
| **Polish** | 10 | Table width optimization, IPv6 support, log export indices |

### Key Optimizations

**1. Subprocess Caching**
```bash
# Before: Multiple `lspci -k` calls per scan
# After: Single call, cached in $_LSPCI_CACHE
```

**2. Algorithm Improvement**
```bash
# strip_ansi(): O(n²) bash regex loop → O(n) sed single pass
# Significant speedup for large table outputs
```

**3. Fork Reduction**
```bash
# readlink -f only if path is actually a symlink
[[ -L "$fs" ]] && resolved="$(readlink -f "$fs")" || resolved="$fs"
```

**4. Memory Efficiency**
```bash
# Single `lsmod` call, derive loaded_count from cached output
# Avoided 3 separate `free` calls by using single process substitution
```

**5. Timeout Guards**
```bash
# Prevent hangs on slow devices
timeout 15 lsusb -v 2>/dev/null | head -100
timeout 10 journalctl -k -p 3 ...
```

---

## Security & Safety

### Read-Only Guarantee
- No write operations to system files
- No configuration modifications
- No state-changing binary execution

### Temp File Security
```bash
# Secure temp file creation
jctl_err="$(mktemp)" || { warn "Cannot create temp file"; return 1; }

# Cleanup on exit (including SIGINT)
trap 'rm -f "$jctl_err" 2>/dev/null' RETURN

# Early trap clearing to avoid nesting conflicts
trap - RETURN
```

### Symlink Resolution
```bash
# Prevent cross-filesystem symlink attacks in disk space checks
if [[ -L "$target" ]]; then
    resolved="$(readlink -f "$target")"
else
    resolved="$target"
fi
```

### DoS Prevention
```bash
# Query length limits (wiki mode)
if [[ -z "$query" || ${#query} -gt 50 ]]; then
    echo "-1"
    return 1
fi

# Timeout on external commands
timeout 10 journalctl ...
timeout 15 lsusb -v ...
```

---

## Real-World Use Cases

### 1. Broken System Diagnosis
```bash
# System won't boot properly - check previous boot errors
sudo ./arch-diag.sh --kernel --boot=-1 --save
```

### 2. Service Failure Debugging
```bash
# Check why a service failed to start
sudo ./arch-diag.sh --user --boot=0
```

### 3. Driver Troubleshooting
```bash
# Verify GPU and network driver attachment
./arch-diag.sh --driver --vga
```

### 4. Post-Update Verification
```bash
# Check for pacman errors after system upgrade
sudo ./arch-diag.sh --kernel --user --save
```

### 5. Hardware State Snapshot
```bash
# Full hardware overview without log noise
./arch-diag.sh --system --save
```

### 6. Recovery Environment
```bash
# In chroot or rescue mode - full diagnostic with export
sudo ./arch-diag.sh --save-all
```

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `Permission denied` on `/var/log/pacman.log` or `/sys` | Run with `sudo` |
| Incomplete export files | Check disk space: `df -h .` |
| `journalctl: Failed to open` | Journal may be inaccessible; try `sudo` |
| No temperature sensors detected | Some systems don't expose hwmon; this is normal |
| `coredumpctl not available` | Install `systemd` or ignore (optional feature) |
| Wiki group not found | Use fuzzy matching; check available groups with `--wiki` |

### Verbose Debugging
```bash
# Run with bash debug mode
bash -x ./arch-diag.sh --kernel 2>&1 | head -100
```

---

## Project Status

- **Version:** 1.0.3
- **Tested On:** Arch Linux, CachyOS, Manjaro, EndeavourOS
- **Changelog:** See `log.md` for complete commit history

---

## License

MIT License - See LICENSE file for details.

---

## Acknowledgments

Built on the Arch Linux ecosystem and systemd project. Special thanks to the Arch Wiki contributors whose documentation powers the `--wiki` mode.

---

**arlogkn** - Read-only diagnostic tool for Arch Linux. Safe, dependency-free, comprehensive.

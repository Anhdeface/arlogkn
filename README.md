# arlogkn

**Version:** 1.0.8 | **Platform:** Arch Linux and derivatives | **License:** MIT

A read-only system diagnostic and log extraction utility for Arch Linux. Performs comprehensive hardware and software state analysis without external dependencies.

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [What It Does](#what-it-does)
3. [Why Single File?](#why-single-file)
4. [Requirements](#requirements)
5. [Installation](#installation)
6. [Usage Guide](#usage-guide)
7. [Export Options](#export-options)
8. [Wiki Mode](#wiki-mode)
9. [Scan Capabilities](#scan-capabilities)
10. [Frequently Asked Questions](#frequently-asked-questions)
11. [Troubleshooting](#troubleshooting)
12. [Security & Safety](#security--safety)
13. [License](#license)

---

## Quick Start

```bash
# Make executable (first time only)
chmod +x arch-diag.sh

# Run full system scan
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

**Read-Only Guarantee:** The script never modifies system state, configurations, or executes state-changing binaries. Safe for production and recovery environments.

---

## Why Single File?

**Design Decision:** arlogkn is intentionally a single bash file (~4000 lines) rather than a modular project structure.

**Rationale:**

1. **Portability** - Copy one file to any Arch system and run. No installation, no dependencies, no build process.

2. **Recovery Scenarios** - When a system is broken, you cannot rely on package managers or complex setups. A single script works in chroot, rescue mode, or minimal installations.

3. **Speed** - No module loading overhead, no import resolution. The script starts executing immediately.

4. **Audit Simplicity** - Security reviewers can audit one file end-to-end rather than tracing through multiple modules.

5. **Distribution** - Share via gist, pastebin, or USB drive. No git repository required.

**Trade-offs Accepted:**

- Larger file to navigate (mitigated by clear section headers and comments)
- No code reuse across files (mitigated by internal helper functions)
- Single point of failure (mitigated by comprehensive testing)

This design prioritizes operational convenience over software engineering conventions. For a diagnostic tool used in emergency situations, this trade-off is deliberate and justified.

---

## Requirements

| Category | Details |
|----------|---------|
| **Operating System** | Arch Linux, CachyOS, Manjaro, EndeavourOS, or any systemd-based Linux |
| **Shell** | bash 5.0 or later |
| **Core Utilities** | coreutils, util-linux, systemd, awk, sed, grep |
| **Permissions** | Root (sudo) recommended for full visibility into /var/log, /sys, and protected logs |

**No External Dependencies:** Does not require inxi, hwinfo, or other diagnostic packages.

---

## Installation

No installation required. The script is standalone:

```bash
# Clone repository
git clone <repository-url>
cd arlogkn

# Make executable
chmod +x arch-diag.sh

# Run
./arch-diag.sh
```

**Alternative:** Download the script directly and run. No build step, no package manager needed.

---

## Usage Guide

### Basic Commands

| Command | Purpose |
|---------|---------|
| `./arch-diag.sh` | Full system scan (default) |
| `./arch-diag.sh --kernel` | Kernel errors only |
| `./arch-diag.sh --kernel --boot=-1` | Previous boot kernel errors |
| `./arch-diag.sh --system` | Hardware scan (no logs) |
| `./arch-diag.sh --save` | Export to separate files |
| `./arch-diag.sh --save-all` | Export to single file |
| `./arch-diag.sh --wiki` | Arch Wiki command reference |
| `./arch-diag.sh --wiki=sound` | Specific wiki group |
| `./arch-diag.sh --help` | Show help and exit |

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
# Export to separate files
./arch-diag.sh --save

# Export to single consolidated file
./arch-diag.sh --save-all
```

---

## Export Options

### Separate Files (--save)

Creates timestamped directory with individual log files:

```
./arch-diag-logs/20260302_120000/
├── kernel_errors.txt
├── kernel_errors_clustered.txt
├── service_errors.txt
├── coredumps.txt
├── pacman_errors.txt
├── mounts.txt
├── usb_devices.txt
├── vga_info.txt
├── drivers.txt
├── temperatures.txt
├── boot_timing.txt
├── network_interfaces.txt
└── summary.txt
```

### Single File (--save-all)

Creates one consolidated file:

```
./arch-diag-logs/20260302_120000/arch-log-inspector-all.txt
```

Contains all sections in raw format (no ANSI color codes). Suitable for sharing, archiving, or attaching to bug reports.

---

## Wiki Mode

Interactive Arch Wiki command reference with 20 topic groups and fuzzy matching.

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

**Supported Groups:**

```
pacman, aur, system, process, hardware, disk, network, user, logs,
arch, performance, backup, troubleshooting, boot, memory, graphics,
sound, systemd, file, emergency
```

**Fuzzy Matching Examples:**

```bash
./arch-diag.sh --wiki=soud      # Suggests "sound"
./arch-diag.sh --wiki=netwok    # Suggests "network"
./arch-diag.sh --wiki=grafix    # Suggests "graphics"
```

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

## Frequently Asked Questions

### Do I need to run as root?

**Recommended but not required.** The script runs without root, but some diagnostics require elevated privileges:

- `/var/log/pacman.log` - Requires root for read access
- `/sys` filesystem - Some paths restricted to root
- `journalctl` - Full logs require root

**Best practice:** Run with `sudo` for complete diagnostics.

### Why is the script so large?

The script is ~4000 lines because it:

- Implements 12+ scan modules
- Includes offline Arch Wiki reference (20 command groups)
- Handles edge cases and error conditions
- Contains security mitigations (TOCTOU prevention, symlink protection, DoS limits)
- Has no external dependencies (implements everything internally)

### Is it safe to run on production systems?

**Yes.** The script is strictly read-only:

- No write operations to system files
- No configuration modifications
- No execution of state-changing binaries
- Secure temp file handling with cleanup
- Symlink attack prevention

### Why not use inxi or hwinfo?

Those tools require installation. arlogkn is designed for:

- Broken systems where packages cannot be installed
- Minimal installations without extra utilities
- Recovery environments with limited package access
- Quick diagnostics without dependency management

### Can I use this on non-Arch systems?

**Possible but not recommended.** The script assumes:

- systemd as init system
- pacman as package manager
- Arch-specific log locations
- Arch Wiki command reference

For generic Linux, consider alternatives like `inxi`, `neofetch`, or `hwinfo`.

### How do I report bugs or security issues?

Open an issue on the repository. For security vulnerabilities, please use responsible disclosure and allow time for a fix before public disclosure.

### What is the performance impact?

The script is optimized for speed:

- Caches expensive system calls (lspci, driver detection)
- Uses pure bash operations where possible (80-90% fewer subprocesses)
- Limits output to reasonable sizes (500 lines max for logs)
- Typical runtime: 2-5 seconds for full scan

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `Permission denied` on `/var/log/pacman.log` or `/sys` | Run with `sudo` |
| Incomplete export files | Check disk space: `df -h .` |
| `journalctl: Failed to open` | Journal may be inaccessible; try `sudo` |
| No temperature sensors detected | Some systems do not expose hwmon; this is normal |
| `coredumpctl not available` | Install systemd or ignore (optional feature) |
| Wiki group not found | Use fuzzy matching; check available groups with `--wiki` |

### Verbose Debugging

```bash
# Run with bash debug mode
bash -x ./arch-diag.sh --kernel 2>&1 | head -100
```

---

## Security & Safety

### Read-Only Guarantee

- No write operations to system files
- No configuration modifications
- No execution of state-changing binaries

### TOCTOU Race Condition Prevention

Uses `mkdir --no-dereference` to prevent symlink attacks during directory creation. Post-condition checks verify created paths are not symlinks.

### Path Traversal Protection

Blocks writes to 15+ sensitive directories:

```
/etc, /bin, /sbin, /usr, /boot, /root
/home, /tmp, /var, /proc, /sys, /dev, /run, /opt
```

### Memory Exhaustion Prevention

All journalctl calls limited to 500 lines maximum. Prevents DoS via log flooding or kernel panic loops.

### Temp File Security

Secure temp file creation with automatic cleanup on exit or interrupt.

### DoS Prevention

- Timeout on external commands (10s for journalctl, 15s for lsusb)
- Query length limits in wiki mode (50 characters max)
- Bounded output sizes throughout

---

## License

MIT License. See LICENSE file for details.

---

## Acknowledgments

Built on the Arch Linux ecosystem and systemd project. Special thanks to the Arch Wiki contributors whose documentation powers the `--wiki` mode.

---

**arlogkn** - Read-only diagnostic tool for Arch Linux. Safe, dependency-free, comprehensive.

# arlogkn

**Version:** 1.0.10 | **Platform:** Linux (Multi-distro with Arch optimizations) | **License:** MIT

A read-only system diagnostic and log extraction utility for Linux systems.

---

## Architecture & Build System

The project utilizes a plugin-based modular architecture (`src/core/` and `src/plugins/`) that compiles into a single executable bash script. This design ensures developer maintainability while preserving the portability of a single-file deployment.

- **Modular Codebase:** Core functionalities (hardware, logs, utils) are separated from OS-specific plugins (e.g., `pacman`).
- **Build System:** `build.sh` concatenates the modules and dynamically injects version variables.
- **Graceful Degradation:** The script verifies the operating system at runtime. If an Arch-targeted build is executed on a non-Arch system (e.g., Ubuntu), it safely disables Arch-specific modules and emits a warning, allowing core scans to continue without errors.

---

## Quick Start

### 1. Build the Script
```bash
chmod +x build.sh

# Build with Arch Linux plugins
./build.sh --target arch

# Or build the universal core only
./build.sh --target universal
```

### 2. Run Diagnostics
The compiled script is generated at `build/output/sys-diag.sh`.

```bash
cd build/output
./sys-diag.sh                    # Full scan
./sys-diag.sh --kernel --boot=-1 # Previous boot errors
./sys-diag.sh --save-all         # Export to file
```

---

## What It Does

Extracts diagnostic information from:

- **Kernel logs** — Errors from journalctl -k
- **System services** — Failed units, journal errors
- **Hardware state** — GPU, drivers, temperatures, USB, network
- **Boot performance** — systemd-analyze timing
- **Package logs** — pacman errors and warnings (if supported)
- **Crash dumps** — coredumpctl entries

**Read-Only:** Does not modify system state or configurations.

---

## Requirements

| Category | Details |
|----------|---------|
| **OS** | Linux (Arch, Debian, RHEL, etc.) |
| **Shell** | bash 5.0+ |
| **Utilities** | coreutils, util-linux, systemd, awk, sed, grep |
| **Permissions** | Root recommended for full visibility |

**No External Dependencies** — Does not require inxi, hwinfo, etc.

---

## Usage

### Commands

| Command | Purpose |
|---------|---------|
| `./sys-diag.sh` | Full scan |
| `./sys-diag.sh --kernel` | Kernel errors |
| `./sys-diag.sh --kernel --boot=-1` | Previous boot |
| `./sys-diag.sh --system` | Hardware (no logs) |
| `./sys-diag.sh --save` | Export separate files |
| `./sys-diag.sh --save-all` | Export single file |
| `./sys-diag.sh --wiki` | Wiki reference |
| `./sys-diag.sh --wiki=sound` | Specific topic |

### Scan Modes

```bash
./sys-diag.sh --kernel    # Kernel errors
./sys-diag.sh --user      # Services, coredumps
./sys-diag.sh --driver    # Driver status
./sys-diag.sh --vga       # GPU info
./sys-diag.sh --mount     # Filesystems
./sys-diag.sh --usb       # USB devices
./sys-diag.sh --system    # Hardware overview
```

### Export

| Mode | Output |
|------|--------|
| `--save` | Separate files in `./arch-diag-logs/TIMESTAMP/` |
| `--save-all` | Single file `arch-log-inspector-all.txt` |

---

## Wiki Mode

Arch Wiki command reference (20 topics, fuzzy matching).

```bash
./sys-diag.sh --wiki
./sys-diag.sh --wiki=sound
```

**Topics:** pacman, aur, system, process, hardware, disk, network, user, logs, arch, performance, backup, troubleshooting, boot, memory, graphics, sound, systemd, file, emergency.

---

## Scan Modules

| Module | Data Source |
|--------|-------------|
| Kernel Errors | journalctl -k -p 3 |
| Service Errors | systemctl --failed, journalctl -u *.service |
| Core Dumps | coredumpctl list |
| Pacman Logs | /var/log/pacman.log |
| GPU / VGA | /sys/class/drm, lspci |
| Drivers | /sys/class, lspci -k, lsmod |
| Temperatures | /sys/class/hwmon |
| Boot Timing | systemd-analyze |
| Network | /sys/class/net, ip |
| Mounts | /proc/mounts, df |
| USB | /sys/bus/usb/devices |
| System Info | /proc/cpuinfo, /proc/swaps, uptime |

---

## FAQ

### Do I need root?
**Recommended.** Some paths require elevated privileges:
- /var/log/pacman.log
- /sys filesystem
- Full journalctl logs

### Is it safe?
**Yes.** Read-only operations:
- No writes to system files
- No configuration changes
- No state-changing binaries

### Non-Arch systems?
**Yes.** Due to the Graceful Degradation architecture, the script safely disables Arch-specific modules when running on other distributions, preventing execution errors.

---

## Security

### Read-Only
- No writes to system files
- No configuration changes

### Injection Prevention
- Embedded awk (no shell interpolation)
- Input validation for wiki matching
- Query length limits

### TOCTOU Prevention
- mkdir --no-dereference
- Symlink checks

### DoS Prevention
- 500-line journal limits
- Command timeouts (10s-15s)
- Numeric input validation

---

## License

MIT License.

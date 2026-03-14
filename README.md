# arlogkn

**Version:** 1.0.9 | **Platform:** Arch Linux and derivatives | **License:** MIT

A read-only system diagnostic and log extraction utility for Arch Linux.

---

## Quick Start

```bash
chmod +x arch-diag.sh
./arch-diag.sh                    # Full scan
./arch-diag.sh --kernel --boot=-1 # Previous boot errors
./arch-diag.sh --save-all         # Export to file
```

---

## What It Does

Extracts diagnostic information from:

- **Kernel logs** — Errors from journalctl -k
- **System services** — Failed units, journal errors
- **Hardware state** — GPU, drivers, temperatures, USB, network
- **Boot performance** — systemd-analyze timing
- **Package logs** — pacman errors and warnings
- **Crash dumps** — coredumpctl entries

**Read-Only:** Does not modify system state or configurations.

---

## Why Single File?

**Design Decision:** Single bash file (~4600 lines) for portability.

**Rationale:**

1. **Portability** — Copy one file, run anywhere. No installation.
2. **Recovery** — Works in chroot, rescue mode, minimal installations.
3. **Speed** — No module loading, starts immediately.
4. **Audit** — Single file to review end-to-end.

**Trade-offs:**

- Larger file to navigate
- No modular code reuse

---

## Requirements

| Category | Details |
|----------|---------|
| **OS** | Arch Linux, CachyOS, Manjaro, EndeavourOS, or systemd-based |
| **Shell** | bash 5.0+ |
| **Utilities** | coreutils, util-linux, systemd, awk, sed, grep |
| **Permissions** | Root recommended for full visibility |

**No External Dependencies** — Does not require inxi, hwinfo, etc.

---

## Installation

```bash
git clone <repository-url>
cd arlogkn
chmod +x arch-diag.sh
./arch-diag.sh
```

---

## Usage

### Commands

| Command | Purpose |
|---------|---------|
| `./arch-diag.sh` | Full scan |
| `./arch-diag.sh --kernel` | Kernel errors |
| `./arch-diag.sh --kernel --boot=-1` | Previous boot |
| `./arch-diag.sh --system` | Hardware (no logs) |
| `./arch-diag.sh --save` | Export separate files |
| `./arch-diag.sh --save-all` | Export single file |
| `./arch-diag.sh --wiki` | Wiki reference |
| `./arch-diag.sh --wiki=sound` | Specific topic |

### Scan Modes

```bash
./arch-diag.sh --kernel    # Kernel errors
./arch-diag.sh --user      # Services, coredumps
./arch-diag.sh --driver    # Driver status
./arch-diag.sh --vga       # GPU info
./arch-diag.sh --mount     # Filesystems
./arch-diag.sh --usb       # USB devices
./arch-diag.sh --system    # Hardware overview
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
./arch-diag.sh --wiki
./arch-diag.sh --wiki=sound
./arch-diag.sh --wiki=graphics
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

### Why ~4600 lines?

- 12+ scan modules
- Offline Arch Wiki (20 topics)
- Edge case handling
- Security mitigations
- No external dependencies

### Is it safe?

**Yes.** Read-only operations:
- No writes to system files
- No configuration changes
- No state-changing binaries

### Why not inxi/hwinfo?

Designed for broken systems where packages cannot be installed.

### Non-Arch systems?

**Possible.** Assumes systemd, pacman, Arch log locations.

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Permission denied | Run with sudo |
| Incomplete exports | Check disk space |
| journalctl failed | Try sudo |
| No temperatures | Some systems lack hwmon |
| Wiki not found | Use fuzzy matching |

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

---

**arlogkn** — Read-only diagnostic tool for Arch Linux.

4acf5e7 2026-02-19 Initial commit: arlogkn v1.0
ffde902 2026-02-19 Emphasize 'Read-only' in README description
b753ff3 2026-02-19 feat: add wiki command reference with fuzzy matching and 20 command groups
363d6de 2026-02-20 perf: optimize driver detection and fuzzy matching (v1.0.1)
a6e20d0 2026-02-21 fix: resolve multiple bugs in display detection, table formatting and system checks
2aeeb18 2026-02-21 fix: resolve wiki suggestions, coredump timestamp parsing, and trap isolation
9eb87a0 2026-02-21 feat: add 5 new diagnostic sections - systemctl --failed snapshot in scan_user_services - Hardware temperatures from /sys/class/hwmon - Network interface state from /sys/class/net - Boot timing via systemd-analyze blame - Swap status + zram detection from /proc/swaps - Updated export_all_logs with sections [1.5], [2.5], [7.5] - Updated scan order in main() for SCAN_ALL and SCAN_SYSTEM
cdae09a 2026-02-21 feat/fix: finalize system diagnostics logic, display expansion, and section formatting
a3ba1a1 2026-02-21 fix: optimize network interface table for 80-column TTYs
77d9c8c 2026-02-21 docs: improve README.md with design philosophy and script advantages
6837120 2026-02-21 fix: resolve check_internet crash and enable space syntax for wiki plugin
8a40e34 2026-02-21 perf: remove dead MAC code and optimize memory parsing (phase 7)
720af6c 2026-02-21 fix: refactor journalctl parameter passing to use arrays for boot offset (phase 8)
4b518b4 2026-02-21 fix: change green checkmark to yellow warning for missing boot timing data
0d59aca 2026-02-21 fix: resolve boot timing blame parsing errors on multi-word strings (phase 10)
e26ab2a 2026-02-21 fix: replace ((i++)) with i=$((i+1)) to prevent set -e abort in wiki lookup (phase 11)
ada8aef 2026-02-21 perf: consolidate duplicate lsmod calls in detect_drivers (phase 12)
03a4cbb 2026-02-21 fix: correct lsmod off-by-one count and add missing USB idProduct read (phase 13)
42ca40d 2026-02-21 fix: enable combined flags, multi-monitor detection, and RFC 3339 timestamp parsing (phase 14)
e13ce14 2026-02-21 fix: correct trim logic in boot timing and df symlink resolution in mounts (phase 15)
c3e1fae 2026-02-21 fix: critical dispatch nesting regression and missing IP column in export header (phase 16)
d051423 2026-02-21 fix: table separator width, GPU glob precision, and boot timing float rounding (phase 17)
4449847 2026-02-21 fix: resolve symlinks in check_disk_space for cross-filesystem accuracy (phase 18)
15ecfc9 2026-02-21 fix: prevent flag collision in parse_args and double-scans in main dispatch (phase 19)
debb7be 2026-02-21 fix: cleanup gpu glob in detect_drivers and fix journal warning logic (phase 20)
bd84826 2026-02-21 fix: use unset sentinel for lspci cache and remove redundant driver checks (phase 21)
3ba6c90 2026-02-21 fix: final audit fixes including security, performance, and formatting (phase 22)
4ed3d93 2026-02-21 fix: final audit fixes round 2 including leak traps, lsusb timeouts, and sleep removals (phase 23)
dd9f970 2026-02-24 fix: lspci cache returns empty string instead of nothing when lspci output is empty (phase 24)
eed30af 2026-02-24 fix: add error handling for mktemp failure in scan_kernel_logs (phase 25)
f463e59 2026-02-24 fix: clear RETURN trap early in scan_kernel_logs to avoid nesting conflict (phase 26)
a132583 2026-02-24 fix: replace O(n²) bash regex loop with O(n) sed in strip_ansi() (phase 27)
8ed136d 2026-02-24 fix: inline strip_ansi logic in visible_len() to eliminate subshell overhead (phase 28)
e41a8ec 2026-02-24 fix: check symlink before readlink -f in scan_mounts() to reduce fork overhead (phase 29)
30539db 2026-02-24 fix: narrow platform driver detection to ISA/LPC bridges only, avoid false positives from PCIe/SATA bridges (phase 30)
5f30a31 2026-02-24 docs: update session summary with recent git commits phase 24-30
e3e56c9 2026-02-25 docs: comprehensive README overhaul with usage examples, technical architecture, and real-world use cases
2a746b9 2026-02-25 fix: prevent temp file leak in scan_kernel_logs() after trap - RETURN
032fd4c 2026-02-25 refactor: remove dead code - unused variables and commented functions
550a1ad 2026-02-25 refactor: remove get_pci_driver() dead code
4efc813 2026-02-25 fix: correct lsblk grep pattern in export_usb_devices()
9f023ad 2026-02-25 fix: add missing nullglob in scan_usb_devices() loop
8bdc753 2026-02-25 fix: validate before mutating OUTPUT_DIR in init_output_dir()
17b1bb4 2026-02-25 perf: reduce subprocess spawning in scan_coredumps() tight loop
ca902e7 2026-02-25 perf: reduce loaded_count from 3 subprocesses to 1
87734af 2026-02-25 perf: use pure bash regex in strip_ansi() and visible_len() to eliminate sed subshell
8c30601 2026-02-25 perf: remove draw_footer() no-op function and 28 calls
a2502f9 2026-02-25 refactor: make visible_len() call strip_ansi() to eliminate code duplication
7b3961d 2026-02-25 fix: use bash built-in ${id^} instead of GNU sed \u extension
09c525d 2026-02-25 fix: make os-release parsing more robust with -m1 and -f2-
da58e04 2026-02-25 fix: use bash regex instead of sed for service name highlighting
1671603 2026-02-25 refactor: standardize line counting to use wc -l consistently
aba5988 2026-02-25 fix: sanitize driver names to prevent pipe injection in IFS parsing
c8033a2 2026-02-25 fix: use printf instead of echo to avoid flag interpretation
83370bf 2026-02-25 fix: validate BOOT_OFFSET range to prevent confusing journalctl errors
a1084c7 2026-02-25 docs: restructure SESSION_SUMMARY.md as professional changelog
9e64959 2026-02-25 docs: restore detailed technical changes section in changelog
a04f11b 2026-02-25 fix: infinite loop in service name coloring — use awk instead of bash regex
b2483b0 2026-02-26 fix: scan_coredumps field splitting — awk direct processing instead of read
bca4f6c 2026-02-26 fix: scan_mounts validate use_num before arithmetic comparison
0054401 2026-02-26 perf: check_internet use HEAD request and captive portal endpoint
f538e62 2026-02-26 fix: detect_drivers handle empty lsmod output correctly
cf27eb6 2026-02-26 fix: use trap EXIT instead of RETURN to prevent temp file leak
09084ae 2026-02-26 fix: detect_system_info parse cpupower governor correctly
8779d64 2026-02-26 fix: export_drivers detect lspci availability correctly
b899d68 2026-02-26 perf: remove redundant grep check in journal output validation
aa80211 2026-02-26 perf: scan_system_basics use pure bash instead of 3 awk subprocesses
0bf9f5a 2026-02-26 perf: detect_gpu combine 2 sed processes into 1
e4fac98 2026-02-26 perf: scan_boot_timing use bash extglob instead of sed for trim
225b9a9 2026-02-26 fix: export_drivers remove duplicate virtio in grep pattern
4a4e9f6 2026-02-26 perf: scan_network_interfaces use bash regex instead of grep for IP parsing
d7ffd5b 2026-02-26 fix: detect_drivers collect ALL input drivers instead of just first

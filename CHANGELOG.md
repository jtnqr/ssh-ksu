# Changelog

All notable changes to the `ssh-ksu` project are documented in this file.

## [1.1.1] - 2026-09-23

### Fixed
* **Terminal Compatibility**: Normalized `$TERM` fallbacks in `etc/profile` to prevent crashes when connecting from modern terminal emulators (Ghostty, Kitty, WezTerm) without installed Android terminfo descriptors.

### Changed
* **Licensing**: Formally transitioned project license to GNU General Public License v3.0 (GPL-3.0) to align with bundled GNU utilities (`bash`, `nano`, `rsync`).
* **CI/CD Pipeline**: Modularized GitHub Actions workflow into parallel cross-compilation matrix jobs (`arm64-v8a` and `x86_64`) with isolated build steps.
* **Update Verification**: Stamped `versionCode=3` to verify live in-app update checks via KernelSU and Magisk Manager.

---

## [1.1.0] - 2026-09-12

### Added
* **Native In-App Updates**: Configured `updateJson` endpoint for one-tap update notifications inside KernelSU and Magisk Manager.
* **AOSP Utilitarian WebUI**: Completely redesigned the web interface with clean system styling, WCAG AA compliance, and responsive touch targets.
* **Dynamic Binary Reporting**: Added runtime version probing for bundled utilities (`sshd`, `bash`, `tmux`, `htop`, `nano`, `rsync`).
* **Tap-to-Copy Connect Sync**: Selecting an active network interface dynamically updates the copyable SSH connection string.

### Fixed
* **PID Recycling Race**: Hardened daemon process validation against `/proc/$PID/cmdline` to eliminate process termination races.
* **SELinux PTY Allocation**: Added SELinux policy rules granting `su` domain full permissions over `devpts chr_file`.
* **Config Editor Streaming**: Streamed WebUI configuration saves through base64 encoding to prevent escaping errors.
* **External Link Handling**: Dispatched Android VIEW intents for WebUI repository links, preventing WebView frame crashes.

---

## [1.0.1] - 2026-09-08

### Fixed
* Restored missing module packaging paths for `x86_64` compatibility.
* Corrected path precedence inside `etc/profile`.

---

## [1.0.0] - 2026-09-06

### Added
* Initial release of `ssh-ksu` with isolated mount namespace execution (`unshare -m`).
* Static musl-linked toolchain (`sshd`, `bash`, `tmux`, `htop`, `nano`, `rsync`).
* Basic WebUI dashboard for daemon status and authorized keys management.

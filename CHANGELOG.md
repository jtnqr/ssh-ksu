# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.1] - 2026-09-23

### Changed
- Transition module license to GNU General Public License v3.0 (GPL-3.0) to align with bundled GNU utilities (`bash`, `nano`, `rsync`).
- Modularize GitHub Actions CI/CD pipeline into parallel cross-compilation matrix jobs (`arm64-v8a` and `x86_64`) with isolated build steps.
- Stamp `versionCode=3` to verify in-app OTA update checks via KernelSU and Magisk Manager.

### Fixed
- Normalize `$TERM` fallbacks in `etc/profile` to prevent crashes when connecting from modern terminal emulators (Ghostty, Kitty, WezTerm) without installed Android terminfo descriptors.

## [1.1.0] - 2026-09-12

### Added
- Native in-app update checks via `updateJson` endpoint for KernelSU and Magisk Manager.
- Utilitarian AOSP WebUI layout adhering to WCAG AA accessibility standards.
- Dynamic binary version inspection card ("About & Binaries") probing runtime utilities.
- Tap-to-copy interface selection that updates the SSH connection command dynamically.

### Fixed
- Process termination race condition by validating `/proc/$PID/cmdline` against `sshd` rather than directory existence alone.
- SELinux PTY allocation failure by granting `su` domain full permissions over `devpts chr_file`.
- WebUI configuration save corruption by streaming Base64-encoded payloads into `sshd_config` and `authorized_keys`.
- Android WebView crashes by dispatching `android.intent.action.VIEW` intents for external repository links.

## [1.0.1] - 2026-09-08

### Fixed
- Restore missing module packaging paths for `x86_64` compatibility.
- Correct path precedence inside `etc/profile`.

## [1.0.0] - 2026-09-06

### Added
- Initial release of `ssh-ksu` with isolated mount namespace execution (`unshare -m`).
- Statically linked musl toolchain bundling `sshd`, `bash`, `tmux`, `htop`, `nano`, and `rsync`.
- WebUI dashboard for daemon lifecycle management and public key injection.

[Unreleased]: https://github.com/jtnqr/ssh-ksu/compare/v1.1.1...HEAD
[1.1.1]: https://github.com/jtnqr/ssh-ksu/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/jtnqr/ssh-ksu/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/jtnqr/ssh-ksu/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/jtnqr/ssh-ksu/releases/tag/v1.0.0

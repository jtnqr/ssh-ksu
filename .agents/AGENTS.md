# ssh-ksu Agent & Developer Guide

Welcome! This document provides a complete technical map of the `ssh-ksu` KernelSU/Magisk module. It outlines the architecture, hardened design decisions, folder structure, release process, and verification tools.

---

## 1. Architecture Overview

`ssh-ksu` is a premium, hardened OpenSSH (v10.3p1) and Bash (v5.3) server module designed specifically for Android devices utilizing KernelSU or Magisk. Because Android deviates significantly from traditional POSIX environments, this module implements custom system-level workarounds to provide a seamless, secure, and robust interactive shell experience.

### Technical Stack
* **SSHD**: OpenSSH 10.3p1 (statically compiled for `arm64-v8a`).
* **Shell**: Bash 5.3 (statically compiled with full `ncurses` and `readline` support).
* **Additional Utilities**: GNU Nano (v9.0), htop (v3.5.1), and tmux (v3.6b) with `libevent` (v2.1.12-stable).
* **Compilation Environment**: Dedicated, secure `ubuntu:24.04` container utilizing `musl-cross` toolchains dynamically fetched from GitHub. Android NDK is completely pruned to avoid unnecessary bloat.
* **Environment Sourcing**: Custom interactive login configurations hook via `etc/profile` sourcing `~/.bashrc`.
* **Verification**: Custom isolated user namespace mounting simulator (`tests/run_tests.sh`).

---

## 2. Hardened Design Decisions

### A. The Mount Namespace & OverlayFS Workaround (`unshare -m`)
Stock Android systems completely lack `/etc/passwd` and `/etc/resolv.conf`. Standard bind-mounts fail because these destination files do not exist. To address this:
1. We run the `sshd` daemon inside an isolated mount namespace using `unshare -m`.
2. Inside this namespace, we mount a writeable **OverlayFS** (or fallback to **tmpfs**) over `/system/etc`.
3. **Critical Write-Order Fix**: On some Android ROMs and kernels, path-based SELinux or VFS policies block post-mount write operations to overlayfs-mounted directories. To bypass this, we write the virtual dynamic files (`passwd` and `resolv.conf`) to the writeable `upperdir` (e.g., `/dev/etc_upper/passwd`) **before** mounting overlayfs. When overlayfs is mounted, these files are instantly present and fully writeable, avoiding permission errors.

### B. User Home Folder & Concern Separation
To maintain high security and separate runtime configuration from user state:
* **System & Keys Storage**: Config files, logs, and system ssh host keys reside in `/data/adb/ssh/`.
* **User Isolation**: User-specific configuration (interactive scripts, authorized ssh keys) is isolated inside `/data/adb/ssh/home/` (which serves as the root `$HOME` directory).
* **Automatic Migration**: Any legacy public keys, `.bash_profile`, or `.bashrc` files found in the root directory are automatically migrated to the `/data/adb/ssh/home/` directory during installation and early boot stages.

### C. Flash Longevity & WebUI Protections
* **Flash Longevity**: The module prevents unnecessary flash wear. It caches intermediate state variables and restricts `sed -i` write operations to actual status changes.
* **WebUI Security**: Web interface inputs (configured in `webroot/`) are sanitized via global regex whitelisting, numeric-only PID parsing, and strict command-injection guards.

### D. Hardened Container Compilation
* **Unprivileged Execution**: The compilation environment in `build/Dockerfile` operates completely under a dedicated unprivileged user (`builder`, UID/GID 1000) rather than standard Docker `root` execution, enforcing robust security and matching typical host system permissions.
* **NDK Pruning**: All Android NDK dependencies have been completely removed as the compilation utilizes static `musl-cross` toolchains. This optimizes local and remote cache storage and minimizes the attack surface.

---

## 3. Core Script Components

| File | Purpose | Key Details |
| :--- | :--- | :--- |
| **`service.sh`** | Primary boot startup service (non-blocking). | Waits for boot completed, generates short-keygen Ed25519 system host keys, and launches sshd daemon inside `unshare -m`. |
| **`boot-completed.sh`** | Watchdog and heavy keygen worker. | Executed when boot is complete. Generates RSA 4096 host keys (slow, safe here without timeout) and checks if the service has crashed, restarting it with full mount namespace isolation if needed. |
| **`action.sh`** | Interactive control script. | Handles KSU/Magisk Manager UI interactions. Supports manual starting, stopping, restarting, and real-time status polling. |
| **`customize.sh`** | Installation and environment setup. | Handles permissions, overlays, directories creation (`/data/adb/ssh/home`), data migration, and binary unpacking. |
| **`tests/run_tests.sh`** | QA verification test suite. | Performs shell syntax lints, path alignments, and simulates namespace mounting in an unprivileged user space. |
| **`pack.sh`** | Module release bundler. | Validates static binaries, runs static verification, stages files, and builds the flashable ZIP. |

---

## 4. QA Verification & Testing

To verify the codebase before any commits, run:
```bash
bash tests/run_tests.sh
```
This QA suite runs 19 automated checks:
1. **Syntax Checks**: Validates POSIX/Bash syntax of all core scripts (`service.sh`, `boot-completed.sh`, `action.sh`, `customize.sh`, `uninstall.sh`, and `build/build.sh`) using `bash -n`.
2. **Consistency Checks**: Confirms that module identifier paths and the default shell (`/data/adb/modules/ssh-ksu/system/bin/bash`) are fully aligned across all scripts.
3. **Mount Simulation**: Runs a virtual mount namespace simulation. If the environment supports it (via native root or user namespace `unshare -m`), it runs a mock setup using a custom `tmpfs` over `/dev` to confirm that overlayfs pre-mount writes and tmpfs fallbacks configure `passwd` and `resolv.conf` correctly. If `unshare` is restricted by the kernel (e.g., inside restricted unprivileged container environments), the suite automatically issues a warning and falls back to a graceful mock bypass instead of hard-failing the suite.

---

## 5. Reproducible Build Environment & CI/CD Pipeline

To ensure maximum security, speed, and reproducibility, the project employs a modern containerized compilation system and GitHub Actions pipeline:

### Local Docker Build
1. **Build Container Image**:
   ```bash
   docker build -t ssh-ksu-builder -f build/Dockerfile .
   ```
2. **Compile All Targets**:
   ```bash
   docker run --rm -v "${PWD}:/workspace" ssh-ksu-builder bash build/build.sh all
   ```

### GitHub Actions Workflow Caching & Safeguards
* **Early QA Gating**: The workflow executes `tests/run_tests.sh` under `sudo` immediately after dependency installation. Running under `sudo` allows unprivileged kernel bypasses for testing OverlayFS namespace mounting. If the environment restricts namespaces completely, the script's graceful check bypasses it, preventing pipeline failures due to environment limitations.
* **Two-Tier Caching**:
  1. **musl Toolchain Cache**: Caches `build/.build/toolchains/` (`musl-toolchains-${{ hashFiles('build/build.sh') }}`) to avoid downloading and extracting the 160MB compilers on each run.
  2. **ccache Compiler Cache**: Caches `~/.cache/ccache` (`ccache-${{ runner.os }}-${{ hashFiles('build/build.sh') }}-${{ github.run_id }}`) so incremental builds are lightning fast.
* **Automatic Release Packing**: Fully automates verification checks (`verify.sh`) and outputs checksummed flashable ZIP packages onto workflow artifacts and GitHub Releases.

---

## 6. Release & Versioning Policy

### Overwrite Protection
To enforce strict software configuration rules, `pack.sh` will **never overwrite an existing release ZIP** in the `release/` folder. If a release ZIP for the current version exists, packaging will abort with an error.

### Release Workflow
Whenever you implement a bug fix, addition, or feature:
1. **Bump Versioning**: Update the version tag and increment `versionCode` inside [module.prop](file:///home/jtnqr/module/ssh-ksu/module.prop).
2. **Run Tests**: Execute `bash tests/run_tests.sh` to ensure all QA checks pass.
3. **Build Package**: Package the flashable module for `arm64-v8a` target:
   ```bash
   bash pack.sh --arch arm64-v8a
   ```
4. **Verify ZIP**: The new ZIP file will be placed in `release/ssh-ksu-v[version].zip` alongside its `.sha256` checksum.

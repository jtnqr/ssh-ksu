# ssh-ksu: Statically Compiled OpenSSH and Bash for KernelSU and Magisk

This repository contains the source, configuration scripts, and compilation toolkit for `ssh-ksu`, a hardened OpenSSH and Bash server module designed specifically for Android systems rooted via KernelSU or Magisk. The project compiles standard Linux networking and terminal utilities statically to run seamlessly within Android's constrained user space.

---

## System Operation and Architecture

Android systems lack traditional POSIX structures like `/etc/passwd` and `/etc/resolv.conf`. Directly executing standard Linux binaries on Android typically fails due to missing dynamic library dependencies in Bionic (Android's standard C library) and strict SELinux rules.

To bypass these hurdles, `ssh-ksu` operates as follows:
1. **Static Compilation via musl libc**: All binaries in the package—including OpenSSH, Bash, GNU Nano, htop, and tmux—are statically compiled against `musl libc`. This removes all dependencies on Android's custom system libraries, making the binaries self-contained.
2. **Mount Namespace Isolation (`unshare -m`)**: The SSH daemon is launched inside an isolated mount namespace. This namespace allows the module to mount a private writeable OverlayFS (or fallback to tmpfs) over `/system/etc`.
3. **Virtual Configuration Injection**: Dynamic configuration files (`passwd` and `resolv.conf`) are written to the writable OverlayFS upper directory before mounting. Once mounted, these virtual files appear instantly inside `/etc/`, satisfying OpenSSH's user authentication and hostname resolution requirements.



---

## Core Integrated Utilities

To provide a stable UNIX shell environment, this module packages and configures three layers of core utilities:

### 1. Secure Remote Operations (OpenSSH & rsync)
* **OpenSSH (v10.3p1)**: The module initiates the `sshd` daemon inside the isolated mount namespace, enforcing public-key-only authentication by default. Cryptographically secure Ed25519 system host keys are generated automatically upon module installation and initial startup.
* **rsync (v3.4.2)**: Configured and compiled with static musl integrations, rsync bypasses standard Android file system constraints to allow robust remote file synchronization and direct net-backups without requiring local ADB sessions.

### 2. System Automation (Bash v5.3)
* **Interactive Login Shell**: Standardized GNU Bash replaces Android's minimal `/system/bin/sh` or the restricted `mksh` shell, providing predictable POSIX execution and full readline support for SSH login shells.
* **Unified Environment Sourcing**: The module hooks Bash execution into `/etc/profile` and `~/.bashrc` to dynamically export workspace path variables, terminal configurations, and customized environment variables.

### 3. Interactive Terminal Utilities (htop, tmux, nano)
* **tmux (v3.6b)**: Statically linked with `libevent` (v2.1.12-stable). This grants robust, multiplexed shell session persistence that survives transient network drops or immediate SSH disconnects.
* **htop (v3.5.1)**: Statically compiled process viewer and system resource monitor, allowing you to review thread hierarchies and CPU profiles without nested shell wrapping or memory parsing lags.
* **GNU Nano (v9.0)**: Statically compiled editor with integrated syntax highlighting and terminal fallback compatibility, allowing easy on-device config edits.

---

## Environment Constraints

* **Storage Paths**: System configurations, logs, and system SSH keys are preserved in `/data/adb/ssh/`. To enforce user isolation, all user configurations and authorization files reside in `/data/adb/ssh/home/` (sourcing `$HOME`).
* **Interactive TTY Fallbacks**: Android lacks a standard terminfo database, which normally causes terminal-oriented tools (htop, tmux, nano) to crash immediately upon terminal initialization. This project resolves the crash by compiling fallback terminfo definitions directly into the static `ncursesw` dependency.
* **Write Performance**: To protect flash memory longevity, the system checks internal configuration state variables prior to running writes, preventing unnecessary wear on disk partitions.

---

## Repository Directory Layout

* **`.github/workflows/build.yml`**: GitHub Actions build configuration, optimized with compiler caches.
* **`.agents/AGENTS.md`**: Complete system architecture documentation and development history.
* **`build/Dockerfile`**: Hardened, non-root reproducible compiler container definition.
* **`build/build.sh`**: Source fetching and multi-stage compiler pipeline script.
* **`build/verify.sh`**: Post-compilation script to validate static linkage and ELF architectures.
* **`tests/run_tests.sh`**: Automated QA checks validating scripts, paths, and namespace mounting.
* **`webroot/`**: Dashboard files rendered by Magisk and KernelSU manager applications.
* **`action.sh`**: Interactive start, stop, and status polling script for manager UIs.
* **`service.sh` / `boot-completed.sh`**: Boot sequence daemons and watchdog startup processes.
* **`customize.sh` / `uninstall.sh`**: Module installer and uninstaller lifecycle hooks.
* **`pack.sh`**: Distribution script that assembles target binaries into a flashable ZIP.

---

## Reproducible Compilation Pipeline

The project employs a secure, non-root Docker build container to ensure that compiled binaries can be verified independently.

### Local Compilation Steps

1. **Build the Compiler Container**:
   Build the Debian-based compiler container. The container runs under an unprivileged `builder` user (UID/GID 1000) to ensure files generated match standard user permissions and prevent privilege escalation:
   ```bash
   docker build -t ssh-ksu-builder -f build/Dockerfile .
   ```

2. **Compile Target Architectures**:
   Mount the workspace and trigger the static compiler script. This script fetches the required source archives and compiles them using static musl-cross toolchains:
   ```bash
   docker run --rm -v "${PWD}:/workspace" ssh-ksu-builder bash build/build.sh all
   ```
   Compiled targets are placed in `build/out/` and verified against ELF header requirements.

---

## CI/CD Pipeline and Caching Design

The automated GitHub Actions workflow is optimized for speed and safety:
* **Gated Verification**: The runner executes `tests/run_tests.sh` before entering compilation. Any shell syntax, path, or mock namespace mounting error stops the workflow immediately.
* **Two-Tier Caching**:
  * **musl Toolchains**: Caches pre-built cross-compilers (`build/.build/toolchains/`), saving significant download overhead on subsequent pipeline runs.
  * **ccache**: Caches static build objects, reducing consecutive incremental compiler passes down to seconds.
* **Automated Packaging**: On successful compilation, the workflow stages the binaries, packs them into a flashable ZIP with SHA-256 validation, and prepares a draft release.



---

## Prerequisites

To ensure proper integration and system behavior, this module requires the **MetaModule** framework to function properly:
* **MetaModule Requirement**: The custom namespace mounting operations and system OverlayFS / tmpfs modifications are handled and isolated via MetaModule mounting routines.
* **Loading Constraint**: The module must be loaded through MetaModule to ensure that virtualized files (such as `/etc/passwd` and `/etc/resolv.conf`) are mounted and visible to the target system correctly.

---

## Deployment Guide

### 1. Build the Release Package
To bundle the compiled binaries and module configurations into a flashable package:
```bash
bash pack.sh
```
This produces `release/ssh-ksu-v[version].zip` along with its SHA-256 checksum file.

### 2. Flash the Module
1. Copy the generated ZIP archive to the target Android device.
2. Open the **KernelSU Manager** or **Magisk Manager** app.
3. Select **Install from storage** in the modules view.
4. Select the module ZIP file, wait for unpacking, and reboot the device.

### 3. Inject SSH Keys
Password authentication is disabled for security reasons. Connect the device via ADB and inject your SSH public key into the designated home directory:
```bash
# Push public key to the home directory keys pool
adb push ~/.ssh/id_ed25519.pub /data/adb/ssh/authorized_keys

# Set required permissions
adb shell chmod 600 /data/adb/ssh/authorized_keys
adb shell chown root:root /data/adb/ssh/authorized_keys
```

### 4. Connect Over SSH
Execute the connection command from your host shell over port 22:
```bash
ssh root@<device-ip-address> -p 22
```

---

## Note on Development and Orchestration

This codebase has been assembled and refined utilizing vibe-coding paradigms and automated AI orchestration. While the underlying libraries (OpenSSH, Bash, GNU Nano, tmux) are standard POSIX systems, their alignment with Android's custom userland, the namespace OverlayFS mount routines, and the secure caching pipeline were designed and validated via rapid agentic iterations. This ensures a highly optimized integration that balances structural complexity with strict host constraints.

---

## License

This software is distributed under the terms of the MIT License. Refer to the `LICENSE` file in the root directory for details.

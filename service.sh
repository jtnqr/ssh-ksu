#!/system/bin/sh
# service.sh
# Runs in the background after the system has mounted overlayfs (NON-BLOCKING).
# Purpose: generate Ed25519 host key if needed, then start the sshd daemon.
# SELinux rules are loaded automatically from sepolicy.rule by KernelSU.

# ---------------------------------------------------------------------------
# Resolve module directory — critical for overlayfs where $PATH may not
# yet include the module's /system/bin overlay.
# ---------------------------------------------------------------------------
MODDIR="${0%/*}"

SSH_DIR="/data/adb/ssh"
SSHD_BIN="$MODDIR/system/bin/sshd"
SSHD_CONFIG="$SSH_DIR/sshd_config"
SSHD_LOG="$SSH_DIR/sshd.log"
SSHD_PID="$SSH_DIR/sshd.pid"

# ---------------------------------------------------------------------------
# 1. Wait until Android has finished booting and network stack is up.
#    sys.boot_completed is set to "1" by the framework after all services
#    have started, including the network and vold decryption.
# ---------------------------------------------------------------------------
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 1
done

# Extra grace period so networking services settle.
sleep 3

# ---------------------------------------------------------------------------
# 2. Guard: do not start a second instance if already running.
# ---------------------------------------------------------------------------
if [ -f "$SSHD_PID" ]; then
    PID="$(cat "$SSHD_PID")"
    # /proc/<pid>/exe is a reliable liveness check without 'ps' flags.
    if [ -d "/proc/$PID" ]; then
        echo "[ssh-ksu] sshd already running (pid=$PID). Exiting." >> "$SSHD_LOG"
        exit 0
    fi
    rm -f "$SSHD_PID"
fi

# ---------------------------------------------------------------------------
# 3. Generate Ed25519 host key if missing.
#    Ed25519 keygen is sub-second and safe to do in service.sh.
#    RSA 4096 (slow) is handled in boot-completed.sh to avoid timeouts.
# ---------------------------------------------------------------------------
if [ ! -f "$SSH_DIR/ssh_host_ed25519_key" ]; then
    echo "root:x:0:0:root:/data/adb/ssh:/data/adb/modules/ssh-ksu/system/bin/bash" > "$SSH_DIR/passwd.tmp"
    unshare -m sh -c "
        mkdir -p /dev/etc
        mkdir -p /dev/etc_upper /dev/etc_work
        if mount -t overlay overlay -o lowerdir=/system/etc,upperdir=/dev/etc_upper,workdir=/dev/etc_work /system/etc 2>/dev/null; then
            cp -f \"$SSH_DIR/passwd.tmp\" /system/etc/passwd 2>/dev/null
        else
            mount -t tmpfs tmpfs /dev/etc
            cp -d -R /system/etc/* /dev/etc/ 2>/dev/null
            cp -f \"$SSH_DIR/passwd.tmp\" /dev/etc/passwd 2>/dev/null
            mount --bind /dev/etc /system/etc
        fi
        HOME=\"$SSH_DIR\" USER=root \"$MODDIR/system/bin/ssh-keygen\" -t ed25519 -f \"$SSH_DIR/ssh_host_ed25519_key\" -N ''
    " >> "$SSHD_LOG" 2>&1
    rm -f "$SSH_DIR/passwd.tmp"
    chown 0:0 "$SSH_DIR/ssh_host_ed25519_key"
    chmod 600 "$SSH_DIR/ssh_host_ed25519_key"
    chcon u:object_r:system_file:s0 "$SSH_DIR/ssh_host_ed25519_key"
    [ -f "$SSH_DIR/ssh_host_ed25519_key.pub" ] && {
        chown 0:0 "$SSH_DIR/ssh_host_ed25519_key.pub"
        chmod 644 "$SSH_DIR/ssh_host_ed25519_key.pub"
        chcon u:object_r:system_file:s0 "$SSH_DIR/ssh_host_ed25519_key.pub"
    }
fi

# ---------------------------------------------------------------------------
# 4. Start sshd.
#
#    Use the absolute path inside $MODDIR to avoid relying on $PATH, which
#    may not reflect the overlayfs overlay at the time this script executes.
#
#    Flags:
#      -f  → explicit config path (outside the module, survives updates)
#      -E  → redirect sshd's own error/info log to a file
#    SELinux rules are loaded from sepolicy.rule by KernelSU at boot.
# ---------------------------------------------------------------------------
# Create a persistent fake passwd file for musl libc
echo "root:x:0:0:root:/data/adb/ssh:/data/adb/modules/ssh-ksu/system/bin/bash" > "$SSH_DIR/passwd"

unshare -m sh -c "
    mkdir -p /dev/etc
    # Attempt to mount overlayfs (fastest, cleanest)
    mkdir -p /dev/etc_upper /dev/etc_work
    if mount -t overlay overlay -o lowerdir=/system/etc,upperdir=/dev/etc_upper,workdir=/dev/etc_work /system/etc 2>/dev/null; then
        cp -f \"$SSH_DIR/passwd\" /system/etc/passwd 2>/dev/null
        echo \"nameserver 8.8.8.8\" > /system/etc/resolv.conf
        echo \"nameserver 1.1.1.1\" >> /system/etc/resolv.conf
    else
        # Fallback to tmpfs + copy (guaranteed to work on all kernels)
        mount -t tmpfs tmpfs /dev/etc
        cp -d -R /system/etc/* /dev/etc/ 2>/dev/null
        cp -f \"$SSH_DIR/passwd\" /dev/etc/passwd 2>/dev/null
        echo \"nameserver 8.8.8.8\" > /dev/etc/resolv.conf
        echo \"nameserver 1.1.1.1\" >> /dev/etc/resolv.conf
        mount --bind /dev/etc /system/etc
    fi

    mkdir -p /dev/empty
    chown 0:0 /dev/empty 2>/dev/null
    chmod 700 /dev/empty 2>/dev/null
    exec \"$SSHD_BIN\" -f \"$SSHD_CONFIG\" -E \"$SSHD_LOG\"
" >> "$SSHD_LOG" 2>&1

echo "[ssh-ksu] sshd launched at $(date)" >> "$SSHD_LOG"

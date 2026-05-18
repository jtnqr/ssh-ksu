#!/system/bin/sh
# boot-completed.sh
# Executed by KernelSU once sys.boot_completed=1 (fully non-blocking).
# Purpose:
#   1. Generate RSA 4096 host key if missing (slow — safe here, no timeout).
#   2. Watchdog: ensure sshd is still running after full boot.

MODDIR="${0%/*}"
SSH_DIR="/data/adb/ssh"
SSHD_BIN="$MODDIR/system/bin/sshd"
SSHD_CONFIG="$SSH_DIR/sshd_config"
SSHD_LOG="$SSH_DIR/sshd.log"
SSHD_PID="$SSH_DIR/sshd.pid"
KEYGEN="$MODDIR/system/bin/ssh-keygen"

# ---------------------------------------------------------------------------
# 1. Generate RSA 4096 host key if still missing.
#    This is done here (not in service.sh) because RSA 4096 keygen can take
#    5–15 seconds on slow SoCs. boot-completed.sh has no timeout limit.
# ---------------------------------------------------------------------------
if [ ! -f "$SSH_DIR/ssh_host_rsa_key" ]; then
    echo "[ssh-ksu] boot-completed: generating RSA 4096 host key..." >> "$SSHD_LOG"
    echo "root:x:0:0:root:/data/adb/ssh:/system/bin/sh" > "$SSH_DIR/passwd.tmp"
    unshare -m sh -c "
        if [ -f /etc/passwd ]; then
            mount --bind \"$SSH_DIR/passwd.tmp\" /etc/passwd 2>/dev/null
        fi
        HOME=\"$SSH_DIR\" USER=root \"$KEYGEN\" -t rsa -b 4096 -f \"$SSH_DIR/ssh_host_rsa_key\" -N ''
    " >> "$SSHD_LOG" 2>&1
    rm -f "$SSH_DIR/passwd.tmp"
    chown 0:0 "$SSH_DIR/ssh_host_rsa_key"
    chmod 600 "$SSH_DIR/ssh_host_rsa_key"
    chcon u:object_r:system_file:s0 "$SSH_DIR/ssh_host_rsa_key"
    [ -f "$SSH_DIR/ssh_host_rsa_key.pub" ] && {
        chown 0:0 "$SSH_DIR/ssh_host_rsa_key.pub"
        chmod 644 "$SSH_DIR/ssh_host_rsa_key.pub"
        chcon u:object_r:system_file:s0 "$SSH_DIR/ssh_host_rsa_key.pub"
    }
    echo "[ssh-ksu] boot-completed: RSA host key generated." >> "$SSHD_LOG"
fi

# ---------------------------------------------------------------------------
# 2. Watchdog: restart sshd if it died after service.sh launched it.
# ---------------------------------------------------------------------------
NEEDS_START=false

if [ ! -f "$SSHD_PID" ]; then
    NEEDS_START=true
else
    PID="$(cat "$SSHD_PID" 2>/dev/null)"
    if [ -z "$PID" ] || [ ! -d "/proc/$PID" ]; then
        rm -f "$SSHD_PID"
        NEEDS_START=true
    fi
fi

if [ "$NEEDS_START" = true ]; then
    echo "[ssh-ksu] boot-completed: sshd not running — starting now." >> "$SSHD_LOG"
    # Create a persistent fake passwd file for musl libc
    echo "root:x:0:0:root:/data/adb/ssh:/system/bin/sh" > "$SSH_DIR/passwd"
    unshare -m sh -c "
        if [ -f /etc/passwd ]; then
            mount --bind \"$SSH_DIR/passwd\" /etc/passwd 2>/dev/null
        fi
        mkdir -p /dev/empty
        chown 0:0 /dev/empty 2>/dev/null
        chmod 700 /dev/empty 2>/dev/null
        exec \"$SSHD_BIN\" -f \"$SSHD_CONFIG\" -E \"$SSHD_LOG\"
    " >> "$SSHD_LOG" 2>&1
    echo "[ssh-ksu] boot-completed: sshd launched at $(date)" >> "$SSHD_LOG"
else
    echo "[ssh-ksu] boot-completed: sshd healthy (pid=$(cat "$SSHD_PID"))." >> "$SSHD_LOG"
fi

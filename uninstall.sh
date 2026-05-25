#!/system/bin/sh
# uninstall.sh
# Executed by KernelSU when the module is removed (next reboot after removal).
# Purpose: cleanly stop sshd and remove runtime state files.
#
# NOTE: /data/adb/ssh/ is intentionally preserved so that host keys and
#       authorized_keys survive a reinstall. To fully wipe, run:
#           rm -rf /data/adb/ssh

SSH_DIR="/data/adb/ssh"
SSHD_PID="$SSH_DIR/sshd.pid"
LOG="$SSH_DIR/sshd.log"

# Stop running sshd daemon if present.
if [ -f "$SSHD_PID" ]; then
    PID="$(cat "$SSHD_PID" 2>/dev/null)"
    if [ -n "$PID" ] && [ -d "/proc/$PID" ]; then
        kill "$PID" 2>/dev/null
        echo "[ssh-ksu] uninstall: stopped sshd (pid=$PID)" >> "$LOG"
    fi
    rm -f "$SSHD_PID"
fi

# Thoroughly terminate all remaining daemon instances and client connections by process name
pkill sshd 2>/dev/null || true

echo "[ssh-ksu] uninstall: module removed. Keys preserved in $SSH_DIR." >> "$LOG"

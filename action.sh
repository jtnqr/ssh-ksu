#!/system/bin/sh
MODDIR="${0%/*}"
SSH_DIR="/data/adb/ssh"
SSHD_BIN="$MODDIR/system/bin/sshd"
SSHD_CONFIG="$SSH_DIR/sshd_config"
SSHD_LOG="$SSH_DIR/sshd.log"
SSHD_PID="$SSH_DIR/sshd.pid"

ACTION="${1:-restart}"   # default: restart (for KSU action button)

stop_sshd() {
    if [ -f "$SSHD_PID" ]; then
        PID="$(cat "$SSHD_PID" 2>/dev/null)"
        if [ -n "$PID" ] && [ -d "/proc/$PID" ]; then
            kill "$PID" 2>/dev/null && sleep 1
        fi
        rm -f "$SSHD_PID"
    fi
}

start_sshd() {
    if [ ! -f "$SSH_DIR/ssh_host_ed25519_key" ] && [ ! -f "$SSH_DIR/ssh_host_rsa_key" ]; then
        echo "ERROR: No host keys found." ; exit 1
    fi
    echo "root:x:0:0:root:/data/adb/ssh:/system/bin/sh" > "$SSH_DIR/passwd"
    unshare -m sh -c "
        [ -f /etc/passwd ] && mount --bind \"$SSH_DIR/passwd\" /etc/passwd 2>/dev/null
        mkdir -p /dev/empty && chown 0:0 /dev/empty && chmod 700 /dev/empty
        exec \"$SSHD_BIN\" -f \"$SSHD_CONFIG\" -E \"$SSHD_LOG\"
    " >> "$SSHD_LOG" 2>&1
    # wait for PID file
    i=0; while [ $i -lt 6 ]; do [ -f "$SSHD_PID" ] && break; sleep 0.5; i=$((i+1)); done
    # fallback
    if [ ! -f "$SSHD_PID" ]; then
        pid=$(pgrep -f "$SSHD_BIN" 2>/dev/null | head -1)
        [ -n "$pid" ] && echo "$pid" > "$SSHD_PID"
    fi
}

case "$ACTION" in
    stop)    stop_sshd ;;
    start)   start_sshd ;;
    restart) stop_sshd; start_sshd ;;
esac

# keep KSU action button open with live status (only when run interactively with no args)
if [ -z "$1" ]; then
    echo ""; echo "Press X to close."
    while true; do
        if [ -f "$SSHD_PID" ] && [ -d "/proc/$(cat "$SSHD_PID" 2>/dev/null)" ]; then
            echo "● running  $(date '+%H:%M:%S')"
        else
            echo "○ stopped  $(date '+%H:%M:%S')"
        fi
        sleep 5
    done
fi

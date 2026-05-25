#!/system/bin/sh
MODDIR="${0%/*}"
SSH_DIR="/data/adb/ssh"
SSHD_BIN="$MODDIR/system/bin/sshd"
SSHD_CONFIG="$SSH_DIR/sshd_config"
SSHD_LOG="$SSH_DIR/sshd.log"
SSHD_PID="$SSH_DIR/sshd.pid"

ACTION="${1:-restart}"   # default: restart (for KSU action button)

# Helper for unified time-stamped logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$SSHD_LOG"
}

stop_sshd() {
    if [ -f "$SSHD_PID" ]; then
        PID="$(cat "$SSHD_PID" 2>/dev/null)"
        if [ -n "$PID" ] && [ -d "/proc/$PID" ]; then
            kill "$PID" 2>/dev/null && sleep 0.2
        fi
        rm -f "$SSHD_PID"
    fi
    
    # Thoroughly terminate all lingering sshd instances and active client sessions by process name
    pkill sshd 2>/dev/null || true
    sleep 0.5

    # Update module.prop status to Stopped
    [ -f "$MODDIR/module.prop" ] && sed -i 's/Status: Running/Status: Stopped/g' "$MODDIR/module.prop"
}

start_sshd() {
    # Guard: do not start if already running
    if [ -f "$SSHD_PID" ]; then
        PID="$(cat "$SSHD_PID" 2>/dev/null)"
        if [ -n "$PID" ] && [ -d "/proc/$PID" ]; then
            log "[ssh-ksu] start requested but sshd already running (pid=$PID). Exiting."
            exit 0
        fi
        rm -f "$SSHD_PID"
    fi

    if [ ! -f "$SSH_DIR/ssh_host_ed25519_key" ] && [ ! -f "$SSH_DIR/ssh_host_rsa_key" ]; then
        echo "ERROR: No host keys found." ; exit 1
    fi
    
    # Bulletproof: Ensure home directories exist with correct permissions before starting
    mkdir -p "$SSH_DIR/home/.ssh"
    chown -R 0:0 "$SSH_DIR/home"
    chmod 700 "$SSH_DIR/home"
    chmod 700 "$SSH_DIR/home/.ssh"
    
    # Handle legacy authorized_keys migration if present
    if [ -f "$SSH_DIR/authorized_keys" ]; then
        mv "$SSH_DIR/authorized_keys" "$SSH_DIR/home/.ssh/authorized_keys" 2>/dev/null
    fi
    if [ ! -f "$SSH_DIR/home/.ssh/authorized_keys" ]; then
        touch "$SSH_DIR/home/.ssh/authorized_keys"
        chmod 600 "$SSH_DIR/home/.ssh/authorized_keys"
    fi
    
    # Handle legacy .bash_profile migration if present
    if [ -f "$SSH_DIR/.bash_profile" ]; then
        mv "$SSH_DIR/.bash_profile" "$SSH_DIR/home/.bash_profile" 2>/dev/null
    fi
    if [ ! -f "$SSH_DIR/home/.bash_profile" ]; then
        cp "$MODDIR/etc/profile" "$SSH_DIR/home/.bash_profile"
        chmod 644 "$SSH_DIR/home/.bash_profile"
    fi

    # Update module.prop status to Running
    [ -f "$MODDIR/module.prop" ] && sed -i 's/Status: Stopped/Status: Running/g' "$MODDIR/module.prop"

    echo "root:x:0:0:root:/data/adb/ssh/home:/data/adb/modules/ssh-ksu/system/bin/bash" > "$SSH_DIR/passwd"
    unshare -m sh -c "
        mkdir -p /dev/etc
        # Attempt to mount overlayfs (fastest, cleanest)
        mkdir -p /dev/etc_upper /dev/etc_work
        cp -f \"$SSH_DIR/passwd\" /dev/etc_upper/passwd 2>/dev/null
        echo \"nameserver 8.8.8.8\" > /dev/etc_upper/resolv.conf
        echo \"nameserver 1.1.1.1\" >> /dev/etc_upper/resolv.conf

        if mount -t overlay overlay -o lowerdir=/system/etc,upperdir=/dev/etc_upper,workdir=/dev/etc_work /system/etc 2>/dev/null; then
            :
        else
            # Fallback to tmpfs + copy (guaranteed to work on all kernels)
            mount -t tmpfs tmpfs /dev/etc
            cp -d -R /system/etc/* /dev/etc/ 2>/dev/null
            cp -f \"$SSH_DIR/passwd\" /dev/etc/passwd 2>/dev/null
            echo \"nameserver 8.8.8.8\" > /dev/etc/resolv.conf
            echo \"nameserver 1.1.1.1\" >> /dev/etc/resolv.conf
            mount --bind /dev/etc /system/etc
        fi
        mkdir -p /dev/empty && chown 0:0 /dev/empty && chmod 700 /dev/empty
        exec \"$SSHD_BIN\" -f \"$SSHD_CONFIG\" -D -e 2>&1 | while read -r line; do
            echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] \$line\"
        done
    " >> "$SSHD_LOG" 2>&1 &
    log "[ssh-ksu] sshd manually launched via action."
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
    echo "=========================================================="
    echo "                      SSH-KSU MODULE                      "
    echo "=========================================================="
    echo " This interactive action terminal displays real-time status"
    echo " and details about the SSH-KSU buttons & CLI controls."
    echo ""
    echo " 🌐 WebUI Dashboard Button:"
    echo "   - View real-time Port, PID, Uptime, & Clients."
    echo "   - Live-stream and truncate/clear logs dynamically."
    echo "   - Full editor for sshd_config & authorized_keys."
    echo "   - Key generation tools (RSA-4096 / Ed25519)."
    echo ""
    echo " ⚡ Action Button (Terminal):"
    echo "   - Triggered by clicking 'Action' in KernelSU Manager."
    echo "   - Automatically performs a safe restart of the server."
    echo ""
    echo " 💻 Command-Line (CLI) Usage:"
    echo "   You can run this script directly via root shell:"
    echo "     action.sh start   : Start SSH service"
    echo "     action.sh stop    : Stop SSH service"
    echo "     action.sh restart : Restart SSH service"
    echo "=========================================================="
    echo ""
    echo "Press X or back to close this terminal."
    echo ""
    while true; do
        PID="$(cat "$SSHD_PID" 2>/dev/null)"
        if [ -n "$PID" ] && [ -d "/proc/$PID" ]; then
            echo "● running  $(date '+%H:%M:%S')"
        else
            echo "○ stopped  $(date '+%H:%M:%S')"
        fi
        sleep 5
    done
fi


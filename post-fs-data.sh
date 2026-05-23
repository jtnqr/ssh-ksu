#!/system/bin/sh
# post-fs-data.sh
# Runs early in boot (blocking stage — 10 s hard limit).
# Purpose: provision the persistent SSH config directory and permissions.
# NOTE: Host key generation is intentionally NOT done here to avoid hitting
#       the 10-second boot timeout. Keys are generated in:
#         Ed25519 → service.sh (sub-second, safe there)
#         RSA 4096 → boot-completed.sh (slow, needs the extra time)

# ---------------------------------------------------------------------------
# Resolve module directory from the script's own path — works with overlayfs.
# ---------------------------------------------------------------------------
MODDIR="${0%/*}"

# Persistent data directory — lives outside the module so it survives updates.
SSH_DIR="/data/adb/ssh"

# ---------------------------------------------------------------------------
# 1. Create the persistent directory if absent.
# ---------------------------------------------------------------------------
[ -d "$SSH_DIR" ] || mkdir -p "$SSH_DIR"

# Strict ownership and permissions: root only, no world/group access.
chown 0:0  "$SSH_DIR"
chmod 700  "$SSH_DIR"

# Apply a permissive-enough SELinux context so system processes can access it.
chcon u:object_r:system_file:s0 "$SSH_DIR"

# ---------------------------------------------------------------------------
# 2. Privilege-separation sandbox directory.
#    Required for UsePrivilegeSeparation yes in sshd_config.
#    Compiled with --without-privsep-path so sshd won't chroot here,
#    but the directory must exist for the monitor process.
# ---------------------------------------------------------------------------
mkdir -p "$SSH_DIR/empty"
chown 0:0  "$SSH_DIR/empty"
chmod 711  "$SSH_DIR/empty"
chcon u:object_r:system_file:s0 "$SSH_DIR/empty"

# ---------------------------------------------------------------------------
# 3. Harden existing host key permissions (no-op on first boot).
#    Keys are generated later (service.sh / boot-completed.sh).
# ---------------------------------------------------------------------------
for KEY in "$SSH_DIR/ssh_host_rsa_key" "$SSH_DIR/ssh_host_ed25519_key"; do
    [ -f "$KEY" ] || continue
    chown 0:0 "$KEY"
    chmod 600 "$KEY"
    chcon u:object_r:system_file:s0 "$KEY"
done

for PUB in "$SSH_DIR/ssh_host_rsa_key.pub" "$SSH_DIR/ssh_host_ed25519_key.pub"; do
    [ -f "$PUB" ] && {
        chown 0:0 "$PUB"
        chmod 644 "$PUB"
        chcon u:object_r:system_file:s0 "$PUB"
    }
done

# ---------------------------------------------------------------------------
# 4. Create an empty authorized_keys if it doesn't exist yet.
#    Users drop their public keys here to enable key-based login.
# ---------------------------------------------------------------------------
if [ ! -f "$SSH_DIR/authorized_keys" ]; then
    touch "$SSH_DIR/authorized_keys"
fi
chown 0:0 "$SSH_DIR/authorized_keys"
chmod 600 "$SSH_DIR/authorized_keys"
chcon u:object_r:system_file:s0 "$SSH_DIR/authorized_keys"

# ---------------------------------------------------------------------------
# 5. Deploy sshd_config only on first install (preserve user edits later).
# ---------------------------------------------------------------------------
if [ ! -f "$SSH_DIR/sshd_config" ]; then
    cp "$MODDIR/sshd_config" "$SSH_DIR/sshd_config"
    chown 0:0 "$SSH_DIR/sshd_config"
    chmod 600 "$SSH_DIR/sshd_config"
    chcon u:object_r:system_file:s0 "$SSH_DIR/sshd_config"
fi

# ---------------------------------------------------------------------------
# 6. Deploy bash login profile — only on first install (preserve user edits).
#    bash reads ~/.bash_profile for login shells; $HOME is /data/adb/ssh.
# ---------------------------------------------------------------------------
if [ ! -f "$SSH_DIR/.bash_profile" ]; then
    cp "$MODDIR/etc/profile" "$SSH_DIR/.bash_profile"
    chown 0:0 "$SSH_DIR/.bash_profile"
    chmod 644 "$SSH_DIR/.bash_profile"
    chcon u:object_r:system_file:s0 "$SSH_DIR/.bash_profile"
fi

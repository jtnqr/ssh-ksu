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
# 1. Create the persistent directories if absent.
# ---------------------------------------------------------------------------
[ -d "$SSH_DIR" ] || mkdir -p "$SSH_DIR"

# Strict ownership and permissions: root only, no world/group access.
chown 0:0  "$SSH_DIR"
chmod 700  "$SSH_DIR"
chcon u:object_r:system_file:s0 "$SSH_DIR"

# Create the user home and .ssh directories
mkdir -p "$SSH_DIR/home/.ssh"
chown -R 0:0 "$SSH_DIR/home"
chmod 700 "$SSH_DIR/home"
chmod 700 "$SSH_DIR/home/.ssh"
chcon -R u:object_r:system_file:s0 "$SSH_DIR/home"


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
# 4. Handle authorized_keys path and migration.
#    Migrates legacy keys to /data/adb/ssh/home/.ssh/authorized_keys
# ---------------------------------------------------------------------------
if [ -f "$SSH_DIR/authorized_keys" ]; then
    mv "$SSH_DIR/authorized_keys" "$SSH_DIR/home/.ssh/authorized_keys" 2>/dev/null
fi

if [ ! -f "$SSH_DIR/home/.ssh/authorized_keys" ]; then
    touch "$SSH_DIR/home/.ssh/authorized_keys"
fi
chown 0:0 "$SSH_DIR/home/.ssh/authorized_keys"
chmod 600 "$SSH_DIR/home/.ssh/authorized_keys"
chcon u:object_r:system_file:s0 "$SSH_DIR/home/.ssh/authorized_keys"

# ---------------------------------------------------------------------------
# 5. Deploy sshd_config only on first install (preserve user edits later).
#    If the file exists but still points to legacy keys, dynamically migrate it.
# ---------------------------------------------------------------------------
if [ ! -f "$SSH_DIR/sshd_config" ]; then
    cp "$MODDIR/sshd_config" "$SSH_DIR/sshd_config"
    chown 0:0 "$SSH_DIR/sshd_config"
    chmod 600 "$SSH_DIR/sshd_config"
    chcon u:object_r:system_file:s0 "$SSH_DIR/sshd_config"
else
    # Upgrading users: dynamically relocate keys path without wiping other configs
    if grep -q "/data/adb/ssh/authorized_keys" "$SSH_DIR/sshd_config"; then
        sed -i 's|/data/adb/ssh/authorized_keys|/data/adb/ssh/home/.ssh/authorized_keys|g' "$SSH_DIR/sshd_config"
    fi
fi

# ---------------------------------------------------------------------------
# 6. Deploy bash login profile — only on first install (preserve user edits).
#    bash reads ~/.bash_profile for login shells; $HOME is /data/adb/ssh/home.
#    If the profile exists but exports the legacy HOME, dynamically migrate it.
# ---------------------------------------------------------------------------
if [ -f "$SSH_DIR/.bash_profile" ]; then
    mv "$SSH_DIR/.bash_profile" "$SSH_DIR/home/.bash_profile" 2>/dev/null
fi

if [ ! -f "$SSH_DIR/home/.bash_profile" ]; then
    cp "$MODDIR/etc/profile" "$SSH_DIR/home/.bash_profile"
    chown 0:0 "$SSH_DIR/home/.bash_profile"
    chmod 644 "$SSH_DIR/home/.bash_profile"
    chcon u:object_r:system_file:s0 "$SSH_DIR/home/.bash_profile"
else
    # Upgrading users: dynamically relocate HOME path in migrated profiles
    if grep -q "export HOME=/data/adb/ssh$" "$SSH_DIR/home/.bash_profile"; then
        sed -i 's|export HOME=/data/adb/ssh$|export HOME=/data/adb/ssh/home|g' "$SSH_DIR/home/.bash_profile"
    fi
fi

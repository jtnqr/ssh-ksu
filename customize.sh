#!/system/bin/sh
# customize.sh
# Sourced by KernelSU during module installation (not executed directly).
# Runs in BusyBox ash with Standalone Mode enabled.
# Available variables: $MODPATH, $ARCH, $API, $IS64BIT, $KSU, $KSU_VER

ui_print "--------------------------------------------"
ui_print "  ssh-ksu: OpenSSH + rsync for KernelSU"
ui_print "--------------------------------------------"
ui_print ""
ui_print "  Architecture : $ARCH"
ui_print "  Android API  : $API"
ui_print "  KernelSU ver : $KSU_VER"
ui_print ""

# ---------------------------------------------------------------------------
# Architecture extraction (for fat zips)
# ---------------------------------------------------------------------------
if [ -d "$MODPATH/custom_bin" ]; then
    if [ "$ARCH" = "arm64" ]; then
        TARGET_ABI="arm64-v8a"
    elif [ "$ARCH" = "x86" ] || [ "$ARCH" = "x64" ] || [ "$ARCH" = "x86_64" ]; then
        TARGET_ABI="x86_64"
    else
        abort "ERROR: Unsupported architecture: $ARCH"
    fi
    ui_print "  Extracting binaries for $TARGET_ABI..."
    cp -f "$MODPATH/custom_bin/$TARGET_ABI/"* "$MODPATH/system/bin/"
    rm -rf "$MODPATH/custom_bin"
else
    # Single architecture zip, just check if it matches
    # (Assuming arm64 single-arch zip for backward compatibility)
    if [ "$ARCH" != "arm64" ] && [ ! -f "$MODPATH/system/bin/sshd" ]; then
        abort "ERROR: This specific ZIP only includes arm64 binaries (detected: $ARCH)."
    fi
fi

# ---------------------------------------------------------------------------
# Android API check — Android 10 (API 29) minimum recommended.
# Older versions may lack the system calls musl relies on.
# ---------------------------------------------------------------------------
if [ "$API" -lt 29 ]; then
    ui_print "  WARN: Android 10 (API 29) or newer is recommended."
    ui_print "        Detected API $API — proceed at your own risk."
fi

# ---------------------------------------------------------------------------
# Set correct permissions on installed binaries.
# set_perm_recursive: dir owner group dir-perm file-perm [context]
# ---------------------------------------------------------------------------
set_perm_recursive "$MODPATH/system/bin" root root 0755 0755 "u:object_r:system_file:s0"
set_perm "$MODPATH/post-fs-data.sh"  root root 0700 "u:object_r:system_file:s0"
set_perm "$MODPATH/service.sh"       root root 0700 "u:object_r:system_file:s0"
set_perm "$MODPATH/boot-completed.sh" root root 0700 "u:object_r:system_file:s0"
set_perm "$MODPATH/action.sh"        root root 0700 "u:object_r:system_file:s0"
set_perm "$MODPATH/uninstall.sh"     root root 0700 "u:object_r:system_file:s0"
set_perm "$MODPATH/module.prop"      root root 0644 "u:object_r:system_file:s0"
set_perm "$MODPATH/sshd_config"      root root 0600 "u:object_r:system_file:s0"
set_perm "$MODPATH/etc/profile"      root root 0644 "u:object_r:system_file:s0"

# ---------------------------------------------------------------------------
# Metamodule notice.
# The system/ directory (sshd, ssh-keygen, rsync) is only added to $PATH
# if a metamodule such as meta-overlayfs is installed. The sshd daemon
# itself works regardless (service.sh uses an absolute $MODDIR path).
# ---------------------------------------------------------------------------
ui_print ""
ui_print "  NOTE: To use rsync/ssh-keygen from $PATH, install"
ui_print "        a KernelSU metamodule (e.g. meta-overlayfs)."
ui_print "  sshd works without a metamodule."
ui_print ""
ui_print "  On first boot, host keys are generated in:"
ui_print "    /data/adb/ssh/"
ui_print ""
ui_print "  Add your public key to:"
ui_print "    /data/adb/ssh/authorized_keys"
ui_print ""
ui_print "  Then connect via:"
ui_print "    ssh -p 22 root@<device-ip>"
ui_print ""
ui_print "--------------------------------------------"

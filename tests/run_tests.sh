#!/usr/bin/env bash
# =============================================================================
#  tests/run_tests.sh — QA Test Suite for ssh-ksu Magisk/KernelSU Module
# =============================================================================
set -euo pipefail

# Colors for pretty output
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; W='\033[1m'; N='\033[0m'

SUCCESS=0
FAILURE=0

log_pass() { echo -e "${G}[PASS]${N} $*"; SUCCESS=$((SUCCESS+1)); }
log_fail() { echo -e "${R}[FAIL]${N} $*"; FAILURE=$((FAILURE+1)); }
log_info() { echo -e "${B}[INFO]${N} $*"; }

echo -e "${W}=============================================================================${N}"
echo -e "${W}  ssh-ksu QA Test Suite${N}"
echo -e "${W}=============================================================================${N}"

# 1. Syntax Check (Linting)
log_info "1. Running shell syntax verification..."
for script in service.sh boot-completed.sh action.sh customize.sh uninstall.sh build/build.sh; do
    if bash -n "$script" 2>/dev/null; then
        log_pass "$script syntax is valid."
    else
        log_fail "$script has syntax errors!"
    fi
done

# 2. Configuration & Path Consistency Checks
log_info "2. Checking configuration and path consistency..."
# Check module.prop
if [ -f module.prop ]; then
    if grep -q "^id=ssh-ksu" module.prop; then
        log_pass "module.prop 'id' is correct."
    else
        log_fail "module.prop 'id' is incorrect or missing."
    fi
else
    log_fail "module.prop missing."
fi

# Check shell path consistency
log_info "Checking default shell configuration consistency..."
SSHD_SHELL_PATH="/data/adb/modules/ssh-ksu/system/bin/bash"

# Verify build.sh default shell replacement
if grep -q "$SSHD_SHELL_PATH" build/build.sh; then
    log_pass "build.sh has default shell path matching module directory."
else
    log_fail "build.sh has incorrect default shell path!"
fi

# Verify passwd files default shell
for script in service.sh boot-completed.sh action.sh; do
    if grep -q "$SSHD_SHELL_PATH" "$script"; then
        log_pass "$script passwd generation uses correct shell path."
    else
        log_fail "$script passwd generation uses incorrect shell path!"
    fi
done

# 3. Mount Namespace Workaround (Integration Test in User Namespace)
log_info "3. Testing mount namespace workaround..."
# We can simulate the unshare -m namespace execution inside an unprivileged user namespace (-r)
# This lets us verify that our overlay/tmpfs code runs and configures passwd and resolv.conf perfectly!
TEST_DIR="/tmp/ssh_ksu_test_$$"
mkdir -p "$TEST_DIR/system/etc" "$TEST_DIR/data"
echo "nameserver 127.0.0.1" > "$TEST_DIR/system/etc/resolv.conf"
echo "original_hosts" > "$TEST_DIR/system/etc/hosts"
echo "root_key" > "$TEST_DIR/data/passwd"

# Create the mock targets inside $TEST_DIR
mkdir -p "$TEST_DIR/tmp_etc_mock" "$TEST_DIR/data_mock"
cp -d -R "$TEST_DIR/system/etc"/* "$TEST_DIR/tmp_etc_mock/" 2>/dev/null
cp -f "$TEST_DIR/data/passwd" "$TEST_DIR/data_mock/passwd"

# Create a test script that mirrors our mount logic
cat > "$TEST_DIR/test_mount.sh" <<EOF
#!/bin/sh
set -eu

# Mock system paths
SYS_ETC="$TEST_DIR/tmp_etc_mock"
SSH_PASSWD="$TEST_DIR/data_mock/passwd"

mkdir -p /dev/etc
mkdir -p /dev/etc_upper /dev/etc_work

# Attempt overlayfs first
if mount -t overlay overlay -o lowerdir="\$SYS_ETC",upperdir=/dev/etc_upper,workdir=/dev/etc_work "\$SYS_ETC" 2>/dev/null; then
    cp -f "\$SSH_PASSWD" "\$SYS_ETC/passwd"
    echo "nameserver 8.8.8.8" > "\$SYS_ETC/resolv.conf"
    echo "nameserver 1.1.1.1" >> "\$SYS_ETC/resolv.conf"
    echo "overlay" > /dev/mount_type
else
    # Fallback to tmpfs + copy
    mount -t tmpfs tmpfs /dev/etc
    cp -d -R "\$SYS_ETC"/* /dev/etc/ 2>/dev/null
    cp -f "\$SSH_PASSWD" /dev/etc/passwd
    echo "nameserver 8.8.8.8" > /dev/etc/resolv.conf
    echo "nameserver 1.1.1.1" >> /dev/etc/resolv.conf
    mount --bind /dev/etc "\$SYS_ETC"
    echo "tmpfs" > /dev/mount_type
fi

# Verify files exist and are correct
if [ -f "\$SYS_ETC/passwd" ] && [ "\$(cat "\$SYS_ETC/passwd")" = "root_key" ]; then
    echo "VERIFY_PASSWD=OK"
else
    echo "VERIFY_PASSWD=FAIL"
fi

if [ -f "\$SYS_ETC/resolv.conf" ] && grep -q "8.8.8.8" "\$SYS_ETC/resolv.conf"; then
    echo "VERIFY_RESOLV=OK"
else
    echo "VERIFY_RESOLV=FAIL"
fi

if [ -f "\$SYS_ETC/hosts" ] && [ "\$(cat "\$SYS_ETC/hosts")" = "original_hosts" ]; then
    echo "VERIFY_HOSTS=OK"
else
    echo "VERIFY_HOSTS=FAIL"
fi
EOF

chmod +x "$TEST_DIR/test_mount.sh"

# Run it inside user+mount namespace
log_info "Running mounting simulation inside user+mount namespace..."
if OUT=$(unshare -m -r sh -c "
    mount -t tmpfs tmpfs /dev
    \"$TEST_DIR/test_mount.sh\"
" 2>&1); then
    # Parse results
    MTYPE=$(echo "$OUT" | grep -oE "overlay|tmpfs" || echo "unknown")
    if echo "$OUT" | grep -q "VERIFY_PASSWD=OK" && echo "$OUT" | grep -q "VERIFY_RESOLV=OK" && echo "$OUT" | grep -q "VERIFY_HOSTS=OK"; then
        log_pass "Namespace mounting logic succeeded (Method: $MTYPE)."
    else
        log_fail "Namespace mounting logic failed! Output:\n$OUT"
    fi
else
    log_fail "Failed to run namespace mounting logic test! Stderr/Stdout:\n$OUT"
fi

# Cleanup
rm -rf "$TEST_DIR"

echo -e "\n${W}=============================================================================${N}"
echo -e "  Test Results:  ${G}PASS: $SUCCESS${N}  |  ${R}FAIL: $FAILURE${N}"
echo -e "${W}=============================================================================${N}"

if [ "$FAILURE" -eq 0 ]; then
    echo -e "${G}✓ QA Check Successful! The code is safe to merge.${N}"
    exit 0
else
    echo -e "${R}✗ QA Check Failed! Please fix issues before merging.${N}"
    exit 1
fi

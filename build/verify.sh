#!/usr/bin/env bash
# =============================================================================
# verify.sh — Post-build sanity checks for sshd and ssh-keygen binaries
# =============================================================================
# Usage: bash verify.sh [arm64|x86_64|all]   (default: arm64)
# Run this after build.sh completes to confirm the output is correct.
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/out"
TARGET="${1:-arm64-v8a}"

check_abi() {
    local ABI="$1"
    local SSHD="$OUT_DIR/$ABI/sshd"
    local KEYGEN="$OUT_DIR/$ABI/ssh-keygen"
    local RSYNC="$OUT_DIR/$ABI/rsync"
    local SFTP="$OUT_DIR/$ABI/sftp-server"
	local BASH="$OUT_DIR/$ABI/bash"
    local PASS=0 FAIL=0

    echo ""
    echo "=== Verifying $ABI ==="

    # 1. Files exist
    for BIN in "$SSHD" "$KEYGEN" "$RSYNC" "$SFTP" "$BASH"; do
        if [ -f "$BIN" ]; then
            echo "[PASS] Exists: $(basename "$BIN")"
            PASS=$((PASS+1))
        else
            echo "[FAIL] Missing: $BIN"
            FAIL=$((FAIL+1))
        fi
    done

    # 2. ELF architecture check
    for BIN in "$SSHD" "$KEYGEN" "$RSYNC" "$SFTP" "$BASH"; do
        [ ! -f "$BIN" ] && continue
        INFO="$(file "$BIN")"
        case "$ABI" in
            arm64-v8a)
                if echo "$INFO" | grep -q "ARM aarch64"; then
                    echo "[PASS] Arch=aarch64: $(basename "$BIN")"
                    PASS=$((PASS+1))
                else
                    echo "[FAIL] Wrong arch for $ABI: $INFO"
                    FAIL=$((FAIL+1))
                fi
                ;;
            x86_64)
                if echo "$INFO" | grep -q "x86-64"; then
                    echo "[PASS] Arch=x86_64: $(basename "$BIN")"
                    PASS=$((PASS+1))
                else
                    echo "[FAIL] Wrong arch for $ABI: $INFO"
                    FAIL=$((FAIL+1))
                fi
                ;;
        esac
    done

    # 3. Static linkage check (critical — dynamic bins will fail on device)
    for BIN in "$SSHD" "$KEYGEN" "$RSYNC" "$SFTP" "$BASH"; do
        [ ! -f "$BIN" ] && continue
        if file "$BIN" | grep -q "statically linked"; then
            echo "[PASS] Statically linked: $(basename "$BIN")"
            PASS=$((PASS+1))
        else
            echo "[WARN] NOT statically linked: $(basename "$BIN")"
            echo "       This binary requires shared libs — may fail on device!"
            # Not a hard fail — some builds link libdl dynamically (OK)
        fi
    done

    # 4. No Termux/non-system RPATH
    for BIN in "$SSHD" "$KEYGEN" "$RSYNC" "$SFTP" "$BASH"; do
        [ ! -f "$BIN" ] && continue
        if readelf -d "$BIN" 2>/dev/null | grep -qiE "(RPATH|RUNPATH)"; then
            RPATH="$(readelf -d "$BIN" | grep -iE "(RPATH|RUNPATH)")"
            if echo "$RPATH" | grep -q "termux\|data/data"; then
                echo "[FAIL] Termux RPATH found in $(basename "$BIN"): $RPATH"
                FAIL=$((FAIL+1))
            else
                echo "[WARN] RPATH present in $(basename "$BIN"): $RPATH"
            fi
        fi
    done

    # 5. File size sanity (sshd should be >500KB after static link)
    for BIN in "$SSHD" "$KEYGEN" "$RSYNC" "$SFTP" "$BASH"; do
        [ ! -f "$BIN" ] && continue
        SIZE="$(stat -c%s "$BIN" 2>/dev/null || stat -f%z "$BIN")"
        if [ "$SIZE" -gt 524288 ]; then
            echo "[PASS] Size OK ($(numfmt --to=iec "$SIZE" 2>/dev/null || echo "${SIZE}B")): $(basename "$BIN")"
            PASS=$((PASS+1))
        else
            echo "[WARN] Binary suspiciously small (${SIZE} bytes): $(basename "$BIN")"
            echo "       May be a stub or incomplete link."
        fi
    done

    echo "---"
    echo "  PASS=$PASS  FAIL=$FAIL"
    [ "$FAIL" -eq 0 ] && echo "  ✓ All checks passed for $ABI" || echo "  ✗ Fix failures before flashing!"
}

case "${TARGET}" in
    arm64|arm64-v8a) check_abi arm64-v8a ;;
    x86_64)          check_abi x86_64 ;;
    all)             check_abi arm64-v8a; check_abi x86_64 ;;
    *)               echo "Usage: $0 [arm64|x86_64|all]"; exit 1 ;;
esac

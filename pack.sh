#!/usr/bin/env bash
# =============================================================================
# pack.sh — Build and package the ssh-ksu KernelSU/Magisk module ZIP
# =============================================================================
# Usage:
#   bash pack.sh [--version v1.2.0] [--no-verify] [--arch arm64|x86_64|all]
#
# Output:
#   release/ssh-ksu-v1.0.0.zip      ← flashable module ZIP
#   release/ssh-ksu-v1.0.0.zip.sha256
#
# Requirements: zip, sha256sum (or shasum on macOS), awk, sed
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
RELEASE_DIR="$SCRIPT_DIR/release"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
OVERRIDE_VERSION=""
SKIP_VERIFY=false
ARCH_FILTER="arm64-v8a"   # default: primary ABI only in the ZIP

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)  OVERRIDE_VERSION="$2"; shift 2 ;;
        --no-verify) SKIP_VERIFY=true; shift ;;
        --arch)     ARCH_FILTER="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--version v1.x.x] [--no-verify] [--arch arm64|x86_64|all]"
            exit 0
            ;;
        *) echo "[ERROR] Unknown argument: $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Read version from module.prop (authoritative source of truth)
# ---------------------------------------------------------------------------
MODULE_PROP="$SCRIPT_DIR/module.prop"
if [ ! -f "$MODULE_PROP" ]; then
    echo "[ERROR] module.prop not found at: $MODULE_PROP"
    exit 1
fi

prop_get() {
    grep "^${1}=" "$MODULE_PROP" | cut -d= -f2- | tr -d '[:space:]'
}

MOD_ID="$(prop_get id)"
MOD_VERSION="$(prop_get version)"
MOD_VERSION_CODE="$(prop_get versionCode)"
MOD_AUTHOR="$(prop_get author)"

# Allow CLI override of the version tag (does NOT modify module.prop)
if [ -n "$OVERRIDE_VERSION" ]; then
    MOD_VERSION="$OVERRIDE_VERSION"
fi

ZIP_NAME="${MOD_ID}-${MOD_VERSION}.zip"
ZIP_PATH="$RELEASE_DIR/$ZIP_NAME"
CHECKSUM_PATH="${ZIP_PATH}.sha256"

echo "╔════════════════════════════════════════════════════╗"
echo "║  ssh-ksu Module Packer"
echo "║  ID:      $MOD_ID"
echo "║  Version: $MOD_VERSION  (code: $MOD_VERSION_CODE)"
echo "║  Author:  $MOD_AUTHOR"
echo "║  Output:  release/$ZIP_NAME"
echo "╚════════════════════════════════════════════════════╝"
echo ""

# ---------------------------------------------------------------------------
# Validate binaries exist and are built
# ---------------------------------------------------------------------------
validate_binaries() {
    local ABI="$1"
    local MISSING=0
    for BIN in sshd sshd-session sshd-auth ssh-keygen rsync sftp-server bash; do
        local BIN_PATH="$BUILD_DIR/out/$ABI/$BIN"
        if [ ! -f "$BIN_PATH" ]; then
            echo "[ERROR] Missing binary: $BIN_PATH"
            echo "        Run: bash build/build.sh $ABI"
            MISSING=1
        fi
    done
    return $MISSING
}

# ---------------------------------------------------------------------------
# Run verify.sh unless --no-verify was passed
# ---------------------------------------------------------------------------
if [ "$SKIP_VERIFY" = false ] && [ -f "$BUILD_DIR/verify.sh" ]; then
    echo "[VERIFY] Running binary checks..."
    bash "$BUILD_DIR/verify.sh" "${ARCH_FILTER}" || {
        echo "[ERROR] Verification failed. Use --no-verify to skip (not recommended)."
        exit 1
    }
    echo ""
fi

# ---------------------------------------------------------------------------
# Validate required files
# ---------------------------------------------------------------------------
echo "[CHECK] Validating module files..."

REQUIRED_FILES=(
    "module.prop"
    "post-fs-data.sh"
    "service.sh"
    "boot-completed.sh"
    "action.sh"
    "uninstall.sh"
    "customize.sh"
    "sshd_config"
    "sepolicy.rule"
	"webroot/index.html"
    "etc/profile"
    "etc/ksu-status"
)

for F in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$SCRIPT_DIR/$F" ]; then
        echo "[ERROR] Required file missing: $F"
        exit 1
    fi
    echo "        [OK] $F"
done

if [ "$ARCH_FILTER" = "all" ]; then
    PACK_ABIS=("arm64-v8a" "x86_64")
else
    PACK_ABIS=("$ARCH_FILTER")
fi

# Check binaries in build/out/
for ABI in "${PACK_ABIS[@]}"; do
    for BIN in sshd sshd-session sshd-auth ssh-keygen rsync sftp-server bash; do
        BIN_PATH="$BUILD_DIR/out/$ABI/$BIN"
        if [ ! -f "$BIN_PATH" ]; then
            echo "[ERROR] Binary missing from build/out/$ABI/: $BIN"
            echo "        Run: bash build/build.sh $ABI"
            exit 1
        fi
        echo "        [OK] build/out/$ABI/$BIN  ($(du -sh "$BIN_PATH" | cut -f1))"
    done
done
echo ""

# ---------------------------------------------------------------------------
# Prepare staging area
# ---------------------------------------------------------------------------
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT

echo "[STAGE] Assembling module structure..."

# ── Core module files ──────────────────────────────────────────────────────
install -m 644 "$SCRIPT_DIR/module.prop"       "$STAGE_DIR/module.prop"
install -m 700 "$SCRIPT_DIR/post-fs-data.sh"   "$STAGE_DIR/post-fs-data.sh"
install -m 700 "$SCRIPT_DIR/service.sh"        "$STAGE_DIR/service.sh"
install -m 700 "$SCRIPT_DIR/boot-completed.sh" "$STAGE_DIR/boot-completed.sh"
install -m 700 "$SCRIPT_DIR/action.sh"         "$STAGE_DIR/action.sh"
install -m 700 "$SCRIPT_DIR/uninstall.sh"      "$STAGE_DIR/uninstall.sh"
install -m 700 "$SCRIPT_DIR/customize.sh"      "$STAGE_DIR/customize.sh"
install -m 600 "$SCRIPT_DIR/sshd_config"       "$STAGE_DIR/sshd_config"
install -m 644 "$SCRIPT_DIR/sepolicy.rule"     "$STAGE_DIR/sepolicy.rule"

# ── Scripts & Configs ──────────────────────────────────────────────────────
mkdir -p "$STAGE_DIR/etc"
install -m 644 "$SCRIPT_DIR/etc/profile"       "$STAGE_DIR/etc/profile"

# ── Binaries ───────────────────────────────────────────────────────────────
mkdir -p "$STAGE_DIR/system/bin"
install -m 755 "$SCRIPT_DIR/etc/ksu-status"    "$STAGE_DIR/system/bin/ksu-status"

if [ "$ARCH_FILTER" = "all" ]; then
    # Fat zip: put in custom_bin/ folders to be extracted by customize.sh
    for ABI in "${PACK_ABIS[@]}"; do
        mkdir -p "$STAGE_DIR/custom_bin/$ABI"
        for BIN in sshd sshd-session sshd-auth ssh-keygen rsync sftp-server bash; do
            install -m 755 "$BUILD_DIR/out/$ABI/$BIN" "$STAGE_DIR/custom_bin/$ABI/$BIN"
        done
    done
else
    # Single arch zip: put directly in system/bin
    for BIN in sshd sshd-session sshd-auth ssh-keygen rsync sftp-server bash; do
        install -m 755 "$BUILD_DIR/out/$ARCH_FILTER/$BIN" "$STAGE_DIR/system/bin/$BIN"
    done
fi

# ── WebUI ──────────────────────────────────────────────────────────────────
mkdir -p "$STAGE_DIR/webroot"
install -m 644 "$SCRIPT_DIR/webroot/index.html" "$STAGE_DIR/webroot/index.html"
# copy any additional assets alongside index.html if present
if [ -d "$SCRIPT_DIR/webroot" ]; then
    find "$SCRIPT_DIR/webroot" -type f ! -name "index.html" | while read -r f; do
        rel="${f#$SCRIPT_DIR/webroot/}"
        mkdir -p "$STAGE_DIR/webroot/$(dirname "$rel")"
        install -m 644 "$f" "$STAGE_DIR/webroot/$rel"
    done
fi

# ── Build metadata (for debugging / reproducibility) ──────────────────────
BUILD_META="$STAGE_DIR/build_info.txt"
{
    echo "ssh-ksu Build Info"
    echo "=================="
    echo "Packed:      $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "Version:     $MOD_VERSION  (versionCode=$MOD_VERSION_CODE)"
    echo "Arch:        $ARCH_FILTER"
    echo ""
    echo "Binary sizes:"
    for ABI in "${PACK_ABIS[@]}"; do
        echo "  [$ABI]"
        for BIN in sshd sshd-session sshd-auth ssh-keygen rsync sftp-server bash; do
            STAGE_BIN=""
            if [ "$ARCH_FILTER" = "all" ]; then
                STAGE_BIN="$STAGE_DIR/custom_bin/$ABI/$BIN"
            else
                STAGE_BIN="$STAGE_DIR/system/bin/$BIN"
            fi
            printf "    %-12s %s\n" "$BIN" "$(du -sh "$STAGE_BIN" | cut -f1)"
        done
    done
    echo ""
    echo "File list:"
    find "$STAGE_DIR" -type f | sort | sed "s|$STAGE_DIR/||"
} > "$BUILD_META"

echo "[STAGE] Module structure:"
find "$STAGE_DIR" -type f | sort | sed "s|$STAGE_DIR/||" | sed 's/^/        /'
echo ""

# ---------------------------------------------------------------------------
# Create ZIP
# ---------------------------------------------------------------------------
mkdir -p "$RELEASE_DIR"

# Remove stale ZIP if it exists (re-pack flow)
[ -f "$ZIP_PATH" ] && rm -f "$ZIP_PATH"

echo "[ZIP] Creating $ZIP_NAME..."
cd "$STAGE_DIR"
zip -r9 "$ZIP_PATH" . \
    --exclude "*.DS_Store" \
    --exclude "__MACOSX/*"
cd "$SCRIPT_DIR"

ZIP_SIZE="$(du -sh "$ZIP_PATH" | cut -f1)"
echo "[ZIP] Done: $ZIP_PATH  ($ZIP_SIZE)"

# ---------------------------------------------------------------------------
# Generate SHA-256 checksum
# ---------------------------------------------------------------------------
echo "[SHA256] Generating checksum..."
if command -v sha256sum &>/dev/null; then
    sha256sum "$ZIP_PATH" | awk '{print $1}' > "$CHECKSUM_PATH"
elif command -v shasum &>/dev/null; then
    shasum -a 256 "$ZIP_PATH" | awk '{print $1}' > "$CHECKSUM_PATH"
else
    echo "[WARN] sha256sum not found — skipping checksum"
fi

CHECKSUM="$(cat "$CHECKSUM_PATH" 2>/dev/null || echo "N/A")"

# ---------------------------------------------------------------------------
# Release summary
# ---------------------------------------------------------------------------
echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  ✓ Module packed successfully"
echo "║"
echo "║  File:     release/$ZIP_NAME"
echo "║  Size:     $ZIP_SIZE"
echo "║  SHA-256:  $CHECKSUM"
echo "║"
echo "║  Flash via KernelSU Manager or:"
echo "║    adb push release/$ZIP_NAME /sdcard/"
echo "║    adb shell ksud module install /sdcard/$ZIP_NAME"
echo "╚════════════════════════════════════════════════════════════════╝"

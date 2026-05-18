#!/usr/bin/env bash
set -e

# Automatically locate the project root relative to this script's location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- CONFIGURATION ---
REMOTE_USER="jtnqr"
REMOTE_IP="192.168.10.107"
REMOTE_DIR="~/module/ssh-ksu"
LOCAL_OUT_DIR="$PROJECT_ROOT/build/out"
# ---------------------

REMOTE_HOST="${REMOTE_USER}@${REMOTE_IP}"

echo "[1/4] Syncing source code to remote server..."
rsync -avz --delete \
    --exclude='.build' \
    --exclude='release' \
    --exclude='.git' \
    --exclude='build/distcc.env*' \
    "$PROJECT_ROOT/" "${REMOTE_HOST}:${REMOTE_DIR}/"

echo "[2/4] Executing remote optimized native build..."
ssh "$REMOTE_HOST" "
    cd ${REMOTE_DIR}
    rm -f build/distcc.env 2>/dev/null || true
    time bash build/build.sh all
"

echo "[3/4] Creating local output directory..."
mkdir -p "$LOCAL_OUT_DIR"

echo "[4/4] Pulling compiled artifacts back to local machine..."
rsync -avz "${REMOTE_HOST}:${REMOTE_DIR}/build/out/" "$LOCAL_OUT_DIR/"

echo "=== Remote Build & Transfer Complete ==="

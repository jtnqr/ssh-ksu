#!/usr/bin/env bash
# =============================================================================
#  setup-distcc.sh — Prepare distcc + ccache for distributed cross-compilation
#
#  Usage:
#    bash build/setup-distcc.sh user@host1 [user@host2 ...]
#
#  Environment overrides:
#    REMOTE_TC_PATH   Where toolchains land on workers  (default: ~/musl-cross)
#    DISTCC_PORT      distccd listen port on workers    (default: 3632)
#    CCACHE_DIR       Local ccache storage directory    (default: ~/.cache/ccache)
#
#  What it does:
#    1. Verify local deps: distcc, ccache, rsync, ssh
#    2. Download musl toolchains locally (if build.sh hasn't already)
#    3. rsync each toolchain to every worker
#    4. Kill + restart distccd on each worker with toolchain in PATH
#    5. Create ccache→distcc wrapper scripts (handles OpenSSL's "unset CC" issue)
#    6. Run a test compile through the full chain
#    7. Write build/distcc.env  ← sourced automatically by build.sh
# =============================================================================
set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
B='\033[0;34m'; W='\033[1m';    N='\033[0m'

info() { printf "${B}[INFO]${N}  %s\n" "$*"; }
ok()   { printf "${G}[ OK ]${N}  %s\n" "$*"; }
warn() { printf "${Y}[WARN]${N}  %s\n" "$*"; }
die()  { printf "${R}[FAIL]${N}  %s\n" "$*" >&2; exit 1; }
step() { printf "\n${W}── %s ──${N}\n" "$*"; }

# ── Directory layout (mirrors build.sh) ──────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build"
TC_DIR="$BUILD_DIR/toolchains"
WRAPPER_DIR="$BUILD_DIR/wrappers"
ENV_FILE="$SCRIPT_DIR/distcc.env"

# ── Config ────────────────────────────────────────────────────────────────────
REMOTE_TC_PATH="${REMOTE_TC_PATH:-\$HOME/musl-cross}"   # expands on remote
DISTCC_PORT="${DISTCC_PORT:-3632}"
CCACHE_DIR_VAL="${CCACHE_DIR:-$HOME/.cache/ccache}"

# ── ABI → triple mapping (must stay in sync with build.sh) ───────────────────
declare -A ABI_TRIPLE=(
    [arm64-v8a]="aarch64-unknown-linux-musl"
    [x86_64]="x86_64-unknown-linux-musl"
)
declare -A ABI_TARBALL=(
    [arm64-v8a]="aarch64-unknown-linux-musl.tar.xz"
    [x86_64]="x86_64-unknown-linux-musl.tar.xz"
)
ABIS=(arm64-v8a x86_64)
MUSL_CC_BASE="https://github.com/cross-tools/musl-cross/releases/download/20250929"

# ── Parse workers ─────────────────────────────────────────────────────────────
WORKERS=("$@")
if [[ ${#WORKERS[@]} -eq 0 ]]; then
    die "Usage: $0 user@host1 [user@host2 ...]
       e.g.: $0 john@192.168.1.10 john@192.168.1.11"
fi

# =============================================================================
# STEP 1 — Verify local dependencies
# =============================================================================
check_local_deps() {
    step "Checking local dependencies"
    local missing=()
    for cmd in distcc ccache rsync ssh nc curl; do
        if command -v "$cmd" &>/dev/null; then
            local ver
            ver="$("$cmd" --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+[.0-9]*' | head -1 || echo '?')"
            ok "$cmd  $ver"
        else
            warn "$cmd — NOT FOUND"
            missing+=("$cmd")
        fi
    done
    [[ ${#missing[@]} -eq 0 ]] || die "Install missing tools first: ${missing[*]}"
}

# =============================================================================
# STEP 2 — Ensure local toolchains are downloaded
# =============================================================================
ensure_local_toolchains() {
    step "Verifying local musl toolchains"
    mkdir -p "$TC_DIR"
    for ABI in "${ABIS[@]}"; do
        local TRIPLE="${ABI_TRIPLE[$ABI]}"
        local TC_BIN="$TC_DIR/$TRIPLE/bin"
        if [[ -d "$TC_BIN" ]]; then
            ok "$ABI  toolchain present ($TC_BIN)"
            continue
        fi
        local TARBALL="${ABI_TARBALL[$ABI]}"
        local DEST="$TC_DIR/$TARBALL"
        if [[ ! -f "$DEST" ]]; then
            info "Downloading $TARBALL (~80 MB)..."
            curl -fL --progress-bar -o "$DEST.tmp" "$MUSL_CC_BASE/$TARBALL"
            mv "$DEST.tmp" "$DEST"
        fi
        info "Extracting $TARBALL..."
        tar -xf "$DEST" -C "$TC_DIR"
        ok "$ABI  toolchain ready"
    done
}

# =============================================================================
# STEP 3 — rsync toolchains to a worker
#   $1 = HOST
#   $2 = RESOLVED_REMOTE_PATH  (absolute, no shell vars — e.g. /home/user/musl-cross)
# =============================================================================
sync_toolchain_to_worker() {
    local HOST="$1"
    local RESOLVED="$2"
    step "Syncing toolchains → $HOST"
    ssh "$HOST" "mkdir -p '$RESOLVED'"
    for ABI in "${ABIS[@]}"; do
        local TRIPLE="${ABI_TRIPLE[$ABI]}"
        info "rsync  $TRIPLE  → $HOST:$RESOLVED/$TRIPLE"
        rsync -az --info=progress2 --delete \
            "$TC_DIR/$TRIPLE/" \
            "$HOST:$RESOLVED/$TRIPLE/"
        ok "$TRIPLE synced"
    done
}

# =============================================================================
# STEP 4 — Get worker CPU count
# =============================================================================
get_worker_nproc() {
    ssh "$1" "nproc" 2>/dev/null || echo "4"
}

# =============================================================================
# STEP 5 — Start distccd on worker with toolchain in PATH
#   $1 = HOST
#   $2 = NPROC
#   $3 = RESOLVED_REMOTE_PATH  (absolute, no shell vars)
# =============================================================================
start_distccd_on_worker() {
    local HOST="$1"
    local NPROC="$2"
    local RESOLVED="$3"
    step "Starting distccd on $HOST  (jobs=$NPROC, port=$DISTCC_PORT)"

    # Build the colon-separated extra PATH using the resolved absolute path
    local REMOTE_BINS=""
    for ABI in "${ABIS[@]}"; do
        local TRIPLE="${ABI_TRIPLE[$ABI]}"
        REMOTE_BINS="${RESOLVED}/${TRIPLE}/bin:${REMOTE_BINS}"
    done

    # Build compiler name list for verification on the remote
    local COMPILER_NAMES=""
    for ABI in "${ABIS[@]}"; do
        COMPILER_NAMES="${COMPILER_NAMES} ${ABI_TRIPLE[$ABI]}-gcc"
    done

    # Pass variables securely inline to the remote bash session
    ssh "$HOST" "REMOTE_EXTRA_PATH='$REMOTE_BINS' REMOTE_COMPILERS='$COMPILER_NAMES' REMOTE_DISTCC_PORT='$DISTCC_PORT' REMOTE_NPROC='$NPROC' bash -s" <<'REMOTE'
set -e

# Stop any existing distccd — systemd service and any leftover prior run.
if command -v systemctl >/dev/null 2>&1; then
    systemctl --user stop distccd 2>/dev/null || true
    systemctl stop distccd 2>/dev/null || true
fi
if command -v service >/dev/null 2>&1; then
    service distccd stop 2>/dev/null || true
fi
pkill -x distccd 2>/dev/null || true

# Give processes time to fully release the port before we check.
sleep 2

# Prepend toolchain bin dirs (already fully expanded by the client)
export PATH="${REMOTE_EXTRA_PATH}${PATH}"

# Verify every cross-compiler is reachable
for compiler in $REMOTE_COMPILERS; do
    if ! command -v "$compiler" >/dev/null 2>&1; then
        echo "ERROR: $compiler not found in PATH on worker" >&2
        exit 1
    fi
    echo "  OK: $(command -v "$compiler")"
done

# If the port is still occupied after pkill+sleep, kill the specific occupant.
if ss -tlnp 2>/dev/null | grep -q ":${REMOTE_DISTCC_PORT}"; then
    echo "Port ${REMOTE_DISTCC_PORT} still in use after pkill — killing occupant"
    fuser -k "${REMOTE_DISTCC_PORT}/tcp" 2>/dev/null || true
    sleep 2
fi

# Start our own distccd bound to local interfaces on our port.
nohup distccd \
    --daemon \
    --no-detach \
    --port "$REMOTE_DISTCC_PORT" \
    --listen 0.0.0.0 \
    --jobs "$REMOTE_NPROC" \
    --allow 127.0.0.1 \
    --allow 192.168.0.0/16 \
    --allow 10.0.0.0/8 \
    --allow 172.16.0.0/12 \
    --log-file /tmp/distccd-musl.log \
    --nice 5 \
    >/dev/null 2>&1 &

sleep 2
OUR_PID=$(pgrep -f "distccd.*--port ${REMOTE_DISTCC_PORT}" | head -1 || true)
if [ -n "$OUR_PID" ] && ss -tlnp 2>/dev/null | grep -q ":${REMOTE_DISTCC_PORT}"; then
    echo "distccd started OK  (PID ${OUR_PID}, listening on 0.0.0.0:${REMOTE_DISTCC_PORT})"
elif [ -n "$OUR_PID" ]; then
    echo "WARNING: distccd running (PID ${OUR_PID}) but port ${REMOTE_DISTCC_PORT} not yet visible"
else
    echo "ERROR: distccd did not start — see /tmp/distccd-musl.log" >&2
    cat /tmp/distccd-musl.log 2>/dev/null | tail -10 >&2 || true
    exit 1
fi
REMOTE
    ok "distccd running on $HOST:$DISTCC_PORT"
}

# =============================================================================
# STEP 6 — Create ccache + distcc wrapper scripts
#
#  Chain:  ccache → distcc → real cross-compiler
#
#  Why wrappers instead of CC=ccache / CCACHE_PREFIX=distcc?
#  OpenSSL's perl Configure runs in a subshell with "unset CC" and derives
#  the compiler from --cross-compile-prefix, so CC env var is bypassed.
#  A wrapper on PATH is transparent to all build systems.
# =============================================================================
create_wrappers() {
    step "Creating ccache+distcc compiler wrappers"
    mkdir -p "$WRAPPER_DIR"
    for ABI in "${ABIS[@]}"; do
        local TRIPLE="${ABI_TRIPLE[$ABI]}"
        local REAL_BIN="$TC_DIR/$TRIPLE/bin"
        for TOOL in gcc g++ cpp; do
            local REAL_EXE="$REAL_BIN/${TRIPLE}-${TOOL}"
            [[ -f "$REAL_EXE" ]] || continue
            local WRAPPER="$WRAPPER_DIR/${TRIPLE}-${TOOL}"
            cat > "$WRAPPER" <<EOF
#!/bin/sh
# Auto-generated by setup-distcc.sh — do not edit
# Chain: ccache → distcc → ${TRIPLE}-${TOOL}
#
# IMPORTANT: pass the bare compiler name (not the absolute path) to distcc.
# distcc sends the compiler name to the remote worker unchanged. An absolute
# path would fail on the remote (different filesystem layout); a bare name is
# resolved via PATH on both the client and the worker.
#
# Also strip the wrapper directory from PATH so that distcc's local fallback
# resolves to the real compiler instead of looping back into this wrapper.
exec env PATH="${REAL_BIN}:\${PATH}" ccache distcc "${TRIPLE}-${TOOL}" "\$@"
EOF
            chmod +x "$WRAPPER"
            ok "wrapper  ${TRIPLE}-${TOOL}"
        done
    done
}

# =============================================================================
# STEP 7 — Test end-to-end compilation through distcc
# =============================================================================
test_compile() {
    local HOST="$1"
    local ABI="${2:-arm64-v8a}"
    local TRIPLE="${ABI_TRIPLE[$ABI]}"
    local WRAPPER="$WRAPPER_DIR/${TRIPLE}-gcc"

    [[ -f "$WRAPPER" ]] || { warn "Wrapper not found for $TRIPLE — skipping test"; return 0; }

    step "Test compile  [$ABI]  via $HOST"

    local TMPDIR_LOCAL=""
    TMPDIR_LOCAL="$(mktemp -d)"
    # Use ${TMPDIR_LOCAL:-} so set -u doesn't fire in the trap if mktemp failed
    trap 'rm -rf "${TMPDIR_LOCAL:-}"' RETURN

    cat > "$TMPDIR_LOCAL/hello.c" <<'EOF'
int main(void) { return 0; }
EOF

    # Only set DISTCC_HOSTS for this test; don't clobber the real value
    if DISTCC_VERBOSE=0 DISTCC_HOSTS="$HOST:$DISTCC_PORT/4" \
        "$WRAPPER" -c "$TMPDIR_LOCAL/hello.c" -o "$TMPDIR_LOCAL/hello.o" 2>&1; then
        ok "Test compile succeeded via $HOST"
        local ARCH
        ARCH="$(file "$TMPDIR_LOCAL/hello.o" | grep -oE '(ARM aarch64|x86-64)' || echo 'unknown')"
        info "  Output arch: $ARCH"
    else
        warn "Test compile failed — worker may still work; check /tmp/distccd-musl.log on $HOST"
    fi
}

# =============================================================================
# STEP 8 — Write distcc.env
# =============================================================================
write_env() {
    local -a HOST_SPECS=("$@")
    step "Writing $ENV_FILE"

    # Total distcc job slots = sum of all worker nprocs
    local TOTAL_JOBS=0
    local HOSTS_STR=""
    for spec in "${HOST_SPECS[@]}"; do
        # spec format: "host nproc"
        local H="${spec%% *}"
        local N="${spec##* }"
        HOSTS_STR="${HOSTS_STR}${H}:${DISTCC_PORT}/${N},lzo "
        TOTAL_JOBS=$(( TOTAL_JOBS + N ))
    done
    # Add localhost for small files / cache-miss overflow
    local LOCAL_SLOTS=$(( $(nproc) / 2 ))
    [[ $LOCAL_SLOTS -lt 2 ]] && LOCAL_SLOTS=2
    HOSTS_STR="${HOSTS_STR}localhost/${LOCAL_SLOTS}"

    # Recommended make -j: (remote + local) * 1.5, floored
    local DISTCC_JOBS=$(( (TOTAL_JOBS + LOCAL_SLOTS) * 3 / 2 ))

    cat > "$ENV_FILE" <<EOF
# ── distcc + ccache environment ───────────────────────────────────────────────
# Generated by setup-distcc.sh on $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# Re-run setup-distcc.sh to regenerate.

# Worker list  (host:port/max-jobs,compression)
export DISTCC_HOSTS="${HOSTS_STR}"

# Recommended parallelism for make -j
export DISTCC_JOBS=${DISTCC_JOBS}

# Wrapper scripts directory (prepended to PATH in build.sh)
export DISTCC_WRAPPER_PATH="$WRAPPER_DIR"

# ccache settings
export CCACHE_DIR="${CCACHE_DIR_VAL}"
export CCACHE_SLOPPINESS="locale,time_macros"

# Silence distcc job logs (set to 1 to debug)
export DISTCC_VERBOSE=0
export DISTCC_LOG=/tmp/distcc-client.log
EOF

    ok "distcc.env written"
    info "  Workers      : ${HOSTS_STR}"
    info "  make -j slots: $DISTCC_JOBS"
    info "  ccache dir   : $CCACHE_DIR_VAL"
}

# =============================================================================
#  MAIN
# =============================================================================
main() {
    printf "\n${W}╔══════════════════════════════════════════════════╗${N}\n"
    printf   "${W}║  setup-distcc.sh — distcc + ccache setup         ║${N}\n"
    printf   "${W}╚══════════════════════════════════════════════════╝${N}\n\n"
    printf "Workers: %s\n" "${WORKERS[*]}"

    check_local_deps
    ensure_local_toolchains
    create_wrappers

    local -a HOST_SPECS=()

    for WORKER in "${WORKERS[@]}"; do
        info "Configuring worker: $WORKER"

        # Verify SSH connectivity
        if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$WORKER" true 2>/dev/null; then
            die "Cannot SSH into $WORKER — check key auth and connectivity"
        fi
        ok "SSH OK → $WORKER"

        # Check distcc on worker
        if ! ssh "$WORKER" "command -v distccd" &>/dev/null; then
            die "distccd not found on $WORKER — install distcc on the worker first"
        fi
        ok "distccd found on $WORKER"

        # Resolve the remote TC path NOW — expand $HOME on the remote side
        # so rsync (a local process) gets a real absolute path, not a shell var.
        local RESOLVED_REMOTE_PATH
        RESOLVED_REMOTE_PATH="$(ssh "$WORKER" "echo $REMOTE_TC_PATH")"
        info "Remote toolchain path: $RESOLVED_REMOTE_PATH"

        sync_toolchain_to_worker "$WORKER" "$RESOLVED_REMOTE_PATH"

        local NPROC
        NPROC="$(get_worker_nproc "$WORKER")"
        info "Worker CPU count: $NPROC"

        start_distccd_on_worker "$WORKER" "$NPROC" "$RESOLVED_REMOTE_PATH"
        test_compile "$WORKER" "arm64-v8a"

        HOST_SPECS+=("$WORKER $NPROC")
    done

    write_env "${HOST_SPECS[@]}"

    printf "\n${G}${W}✓ Setup complete.${N}  Run your build:\n"
    printf "  bash build/build.sh all\n\n"
    printf "Monitor distcc:\n"
    printf "  distccmon-text 1\n\n"
    printf "Clear ccache:\n"
    printf "  ccache -C\n\n"
    printf "Worker logs:\n"
    for W in "${WORKERS[@]}"; do
        printf "  ssh %s 'tail -f /tmp/distccd-musl.log'\n" "$W"
    done
    printf "\n"
}

main

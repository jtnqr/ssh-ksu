#!/usr/bin/env bash
# =============================================================================
#  build.sh — Cross-compile OpenSSH + OpenSSL + rsync using musl libc
#
#  Why musl instead of Android NDK / Bionic?
#    Bionic is incomplete: missing recallocarray, broken __sentinel__ headers,
#    no proper utmp/lastlog. musl is full POSIX — no patches, no shims.
#    Statically linked musl binaries run on any Android 5.0+ device.
#
#  Usage:
#    bash build/build.sh all          # arm64-v8a + x86_64
#    bash build/build.sh arm64        # arm64-v8a only
#    bash build/build.sh x86_64       # x86_64 only
#    bash build/build.sh clean        # remove build artefacts
#    VERBOSE=1   bash build/build.sh all   # show every compiler line
#    MAKE_JOBS=4 bash build/build.sh all   # limit parallelism
#
#  Host requirements (Linux / WSL2):
#    apt install make autoconf perl curl xz-utils file
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Build behaviour — override on the command line
# ---------------------------------------------------------------------------
VERBOSE="${VERBOSE:-0}"
MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"
MAKE_V=""
[ "$VERBOSE" = "1" ] && {
	MAKE_V="V=1"
	set -x
}

# ---------------------------------------------------------------------------
# ① Version pins
# ---------------------------------------------------------------------------
OPENSSL_VERSION="4.0.0"
OPENSSH_VERSION="10.3p1"
RSYNC_VERSION="3.4.2"
ZLIB_VERSION="1.3.2"
POPT_VERSION="1.19"
NCURSES_VERSION="6.4"
BASH_VERSION="5.3"

# ---------------------------------------------------------------------------
# ② Source URLs
# ---------------------------------------------------------------------------
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"
OPENSSH_URL="https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-${OPENSSH_VERSION}.tar.gz"
RSYNC_URL="https://download.samba.org/pub/rsync/src/rsync-${RSYNC_VERSION}.tar.gz"
ZLIB_URL="https://zlib.net/zlib-${ZLIB_VERSION}.tar.gz"
POPT_URL="http://ftp.rpm.org/popt/releases/popt-1.x/popt-${POPT_VERSION}.tar.gz"
NCURSES_URL="https://ftp.gnu.org/pub/gnu/ncurses/ncurses-${NCURSES_VERSION}.tar.gz"
BASH_URL="https://ftp.gnu.org/gnu/bash/bash-${BASH_VERSION}.tar.gz"

# Pre-built musl cross-compilers from musl.cc
MUSL_CC_BASE="https://github.com/cross-tools/musl-cross/releases/download/20250929"

# ---------------------------------------------------------------------------
# ③ Directory layout
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build"
SRC_DIR="$BUILD_DIR/src"
TC_DIR="$BUILD_DIR/toolchains"
OUT_DIR="$SCRIPT_DIR/out"

mkdir -p "$SRC_DIR" "$TC_DIR" "$OUT_DIR"

# ---------------------------------------------------------------------------
# Distributed build: load distcc + ccache environment if prepared
# Run build/setup-distcc.sh first to generate this file.
# ---------------------------------------------------------------------------
DISTCC_ENV="$SCRIPT_DIR/distcc.env"
if [ -f "$DISTCC_ENV" ]; then
	# shellcheck source=/dev/null
	. "$DISTCC_ENV"
	printf '[setup] distcc+ccache enabled — hosts: %s\n' "${DISTCC_HOSTS:-none}"
	printf '[setup] make -j will use: %s slots\n' "${DISTCC_JOBS:-$MAKE_JOBS}"
	# Honour DISTCC_JOBS unless the user already overrode MAKE_JOBS on the CLI
	MAKE_JOBS="${DISTCC_JOBS:-$MAKE_JOBS}"
fi

# ---------------------------------------------------------------------------
# ④ Helpers
# ---------------------------------------------------------------------------
log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

fetch() {
	local url="$1" dest="$2"
	[ -f "$dest" ] && return 0
	log "Fetching $(basename "$dest")..." >&2
	curl -fL --progress-bar -o "$dest.tmp" "$url" >&2 || {
		rm -f "$dest.tmp"
		return 1
	}
	mv "$dest.tmp" "$dest"
}

# ---------------------------------------------------------------------------
# ⑤ ABI mappings
# ---------------------------------------------------------------------------
abi_to_triple() {
    case "$1" in
        arm64-v8a) echo "aarch64-unknown-linux-musl" ;;
        x86_64)    echo "x86_64-unknown-linux-musl"  ;;
    esac
}

abi_to_openssl_target() {
	case "$1" in
	arm64-v8a) echo "linux-aarch64" ;;
	x86_64) echo "linux-x86_64" ;;
	esac
}

abi_to_tc_tarball() {
    case "$1" in
        arm64-v8a) echo "aarch64-unknown-linux-musl.tar.xz" ;;
        x86_64)    echo "x86_64-unknown-linux-musl.tar.xz"  ;;
    esac
}

# ---------------------------------------------------------------------------
# ⑥ Download + extract musl toolchain (cached after first run)
# ---------------------------------------------------------------------------
setup_toolchain() {
	local ABI="$1"
	local TRIPLE TARBALL TC_BIN
	TRIPLE="$(abi_to_triple "$ABI")"
	TARBALL="$(abi_to_tc_tarball "$ABI")"
    # cross-tools/musl-cross extracts to <triple>/
    TC_BIN="$TC_DIR/${TRIPLE}/bin"

	if [ -d "$TC_BIN" ]; then
		echo "$TC_BIN"
		return 0
	fi

	local DEST_TAR="$TC_DIR/$TARBALL"
	fetch "${MUSL_CC_BASE}/${TARBALL}" "$DEST_TAR" >&2
	log "Extracting musl toolchain for $ABI (~80MB, once only)..." >&2
	tar -xf "$DEST_TAR" -C "$TC_DIR" >&2
	echo "$TC_BIN"
}

# ---------------------------------------------------------------------------
# ⑦ Fetch all source tarballs up-front
# ---------------------------------------------------------------------------
echo "=== Fetching sources ==="
fetch "$OPENSSL_URL" "$SRC_DIR/openssl-${OPENSSL_VERSION}.tar.gz"
fetch "$OPENSSH_URL" "$SRC_DIR/openssh-${OPENSSH_VERSION}.tar.gz"
fetch "$RSYNC_URL"   "$SRC_DIR/rsync-${RSYNC_VERSION}.tar.gz"
fetch "$ZLIB_URL"    "$SRC_DIR/zlib-${ZLIB_VERSION}.tar.gz"
fetch "$POPT_URL"    "$SRC_DIR/popt-${POPT_VERSION}.tar.gz"
fetch "$NCURSES_URL" "$SRC_DIR/ncurses-${NCURSES_VERSION}.tar.gz"
fetch "$BASH_URL"    "$SRC_DIR/bash-${BASH_VERSION}.tar.gz"
echo ""

# =============================================================================
#  BUILD FUNCTION — called once per ABI
# =============================================================================
build_for_abi() {
	local ABI="$1"
	local TRIPLE OPENSSL_TARGET TC_BIN
	TRIPLE="$(abi_to_triple "$ABI")"
	OPENSSL_TARGET="$(abi_to_openssl_target "$ABI")"
	TC_BIN="$(setup_toolchain "$ABI")"

	local WORK_DIR="$BUILD_DIR/$ABI"
	local OPENSSL_INST="$WORK_DIR/openssl-install"
	mkdir -p "$WORK_DIR" "$OPENSSL_INST" "$OUT_DIR/$ABI"

	# -- Toolchain exports ---------------------------------------------------
	# TC_BIN is on PATH so tools can be referenced by basename.
	# Do NOT export CROSS_COMPILE to the shell environment: OpenSSL's Configure
	# writes CC=$(CROSS_COMPILE)${CC} into the Makefile, so if both are set
	# the result is double-prefixed (e.g. aarch64-...-aarch64-...-gcc).
	# CROSS_COMPILE is passed only via --cross-compile-prefix to perl Configure.
	# If distcc wrappers exist, prepend them so every compiler invocation
	# (including OpenSSL's perl Configure subshell) goes through ccache→distcc.
	local CROSS_COMPILE_PFX="${TRIPLE}-"
	if [ -n "${DISTCC_WRAPPER_PATH:-}" ] && [ -d "$DISTCC_WRAPPER_PATH" ]; then
		export PATH="$DISTCC_WRAPPER_PATH:$TC_BIN:$PATH"
	elif command -v ccache >/dev/null 2>&1; then
		local CCACHE_WRAP_DIR="$WORK_DIR/ccache-wrappers"
		mkdir -p "$CCACHE_WRAP_DIR"
		for TOOL in gcc g++ cpp; do
			cat > "$CCACHE_WRAP_DIR/${CROSS_COMPILE_PFX}${TOOL}" <<EOF
#!/bin/sh
exec ccache "$TC_BIN/${CROSS_COMPILE_PFX}${TOOL}" "\$@"
EOF
			chmod +x "$CCACHE_WRAP_DIR/${CROSS_COMPILE_PFX}${TOOL}"
		done
		export PATH="$CCACHE_WRAP_DIR:$TC_BIN:$PATH"
	else
		export PATH="$TC_BIN:$PATH"
	fi
    export CC="${CROSS_COMPILE_PFX}gcc"
    export CXX="${CROSS_COMPILE_PFX}g++"
    export AR="${CROSS_COMPILE_PFX}ar"
    export RANLIB="${CROSS_COMPILE_PFX}ranlib"
    export STRIP="${CROSS_COMPILE_PFX}strip"
    export NM="${CROSS_COMPILE_PFX}nm"

	# -- ABI-specific CPU flags ---------------------------------------------
	# arm64: +crypto enables hardware AES/SHA — huge speedup for SSH sessions
	local ABI_CFLAGS
	case "$ABI" in
	arm64-v8a) ABI_CFLAGS="-march=armv8-a+crypto+sha2+aes -mtune=cortex-a55" ;;
	x86_64) ABI_CFLAGS="-march=x86-64" ;;
	esac

	echo ""
	echo "╔══════════════════════════════════════════════════════════════╗"
	echo "║  ABI: $ABI  ($TRIPLE)"
	echo "║  CC:  $CC"
	echo "║  Arch flags: $ABI_CFLAGS"
	echo "║  Jobs: $MAKE_JOBS  Verbose: $VERBOSE"
	echo "╚══════════════════════════════════════════════════════════════╝"

	build_openssl "$ABI" "$WORK_DIR" "$OPENSSL_INST" "$OPENSSL_TARGET" "$ABI_CFLAGS" "$CROSS_COMPILE_PFX"
    OPENSSL_LIBDIR="$(find "$OPENSSL_INST" -name "libcrypto.a" -printf '%h' -quit)"
    local ZLIB_INST="$WORK_DIR/zlib-install"
	local POPT_INST="$WORK_DIR/popt-install"
	local NCURSES_INST="$WORK_DIR/ncurses-install"
    build_zlib "$ABI" "$WORK_DIR" "$ZLIB_INST" "$ABI_CFLAGS"
	build_popt "$ABI" "$WORK_DIR" "$POPT_INST" "$ABI_CFLAGS"
	build_ncurses "$ABI" "$WORK_DIR" "$NCURSES_INST" "$ABI_CFLAGS"
    build_openssh "$ABI" "$WORK_DIR" "$OPENSSL_INST" "$OPENSSL_LIBDIR" "$ZLIB_INST" "$ABI_CFLAGS"
    build_rsync   "$ABI" "$WORK_DIR" "$POPT_INST" "$ABI_CFLAGS"
    build_bash    "$ABI" "$WORK_DIR" "$NCURSES_INST" "$ABI_CFLAGS"

	echo ""
	log "All binaries for $ABI:"
	ls -lh "$OUT_DIR/$ABI/"
}

# =============================================================================
#  STAGE 1 — OpenSSL (static libcrypto + libssl)
# =============================================================================
build_openssl() {
	local ABI="$1" WORK_DIR="$2" OPENSSL_INST="$3" OPENSSL_TARGET="$4" ABI_CFLAGS="$5" CROSS_PFX="$6"
	local OPENSSL_SRC="$WORK_DIR/openssl-${OPENSSL_VERSION}"

	if [ -f "$OPENSSL_INST/lib/libcrypto.a" ]; then
		log "[OPENSSL] Already built — skipping. (rm $OPENSSL_INST to rebuild)"
		return 0
	fi

	[ -d "$OPENSSL_SRC" ] || tar -xf "$SRC_DIR/openssl-${OPENSSL_VERSION}.tar.gz" -C "$WORK_DIR"

	log "[OPENSSL] Configuring $OPENSSL_TARGET..."
	cd "$OPENSSL_SRC"

	# Pass --cross-compile-prefix instead of exporting CROSS_COMPILE env var.
	# This prevents the double-prefix bug where the Makefile generates:
	#   CC=$(CROSS_COMPILE)${CC}  →  aarch64-...-aarch64-...-gcc
	# Unset all cross-tool env vars so OpenSSL derives them purely from the prefix.
	CC_SAVED="$CC"
	CXX_SAVED="$CXX"
	AR_SAVED="$AR"
	RANLIB_SAVED="$RANLIB"
	NM_SAVED="$NM"

	# Run Configure in a subshell so unsetting cross-tool vars never touches
	# the parent shell — no save/restore needed, failure-safe by design.
	( unset CC CXX AR RANLIB NM CROSS_COMPILE
      perl Configure \
          "$OPENSSL_TARGET" \
          --cross-compile-prefix="$CROSS_PFX" \
          ${ABI_CFLAGS} \
          no-shared    \
          no-tests     \
          no-ui-console \
          no-comp      \
          no-engine    \
          no-dso       \
          no-err       \
          no-camellia  \
          no-cast      \
          no-idea      \
          no-seed      \
          no-bf        \
          no-rc2       \
          no-rc4       \
          no-rc5       \
          --prefix="$OPENSSL_INST" \
          --openssldir="$OPENSSL_INST/ssl"
    )

	log "[OPENSSL] Building static libs (jobs=$MAKE_JOBS)..."
	make -j"$MAKE_JOBS" $MAKE_V build_libs
	make $MAKE_V install_dev

	OPENSSL_LIBDIR="$(find "$OPENSSL_INST" -name "libcrypto.a" -printf '%h' -quit)"
    log "[OPENSSL] libcrypto.a: $(du -sh "$OPENSSL_LIBDIR/libcrypto.a" | cut -f1)"
	cd "$SCRIPT_DIR"
}

# =============================================================================
#  STAGE 2 — zlib (static libz)
# =============================================================================
build_zlib() {
    local ABI="$1" WORK_DIR="$2" ZLIB_INST="$3" ABI_CFLAGS="$4"

    if [ -f "$ZLIB_INST/lib/libz.a" ]; then
        log "[ZLIB]   Already built — skipping."
        return 0
    fi

    local ZLIB_SRC="$WORK_DIR/zlib-${ZLIB_VERSION}"
    [ -d "$ZLIB_SRC" ] || tar -xf "$SRC_DIR/zlib-${ZLIB_VERSION}.tar.gz" -C "$WORK_DIR"

    log "[ZLIB]   Configuring..."
    cd "$ZLIB_SRC"

    # zlib's configure doesn't support --host; use env vars instead
    CFLAGS="${ABI_CFLAGS} -Os -ffunction-sections -fdata-sections -fstack-protector-strong" \
    LDFLAGS="-static" \
    ./configure \
        --prefix="$ZLIB_INST" \
        --static

    log "[ZLIB]   Building..."
    make -j"$MAKE_JOBS" $MAKE_V

    make $MAKE_V install

    log "[ZLIB]   libz.a: $(du -sh "$ZLIB_INST/lib/libz.a" | cut -f1)"
    cd "$SCRIPT_DIR"
}

# =============================================================================
#  STAGE 3 — popt (static libpopt, for rsync)
# =============================================================================
build_popt() {
    local ABI="$1" WORK_DIR="$2" POPT_INST="$3" ABI_CFLAGS="$4"
    local TRIPLE
    TRIPLE="$(abi_to_triple "$ABI")"

    if [ -f "$POPT_INST/lib/libpopt.a" ]; then
        log "[POPT]   Already built — skipping."
        return 0
    fi

    local POPT_SRC="$WORK_DIR/popt-${POPT_VERSION}"
    [ -d "$POPT_SRC" ] || tar -xf "$SRC_DIR/popt-${POPT_VERSION}.tar.gz" -C "$WORK_DIR"

    log "[POPT]   Configuring for $TRIPLE..."
    cd "$POPT_SRC"

    CFLAGS="${ABI_CFLAGS} -Os -ffunction-sections -fdata-sections -fstack-protector-strong" \
    LDFLAGS="-static" \
    ./configure \
        -C \
        --host="$TRIPLE" \
        --build="$(gcc -dumpmachine)" \
        --prefix="$POPT_INST" \
        --disable-shared \
        --enable-static \
        --disable-nls

    make -j"$MAKE_JOBS" $MAKE_V
    make $MAKE_V install

    log "[POPT]   libpopt.a: $(du -sh "$POPT_INST/lib/libpopt.a" | cut -f1)"
    cd "$SCRIPT_DIR"
}

# =============================================================================
#  STAGE 4 — OpenSSH (sshd + ssh-keygen)
#  musl libc is full POSIX — zero Android patches needed.
# =============================================================================
build_openssh() {
    local ABI="$1" WORK_DIR="$2" OPENSSL_INST="$3" OPENSSL_LIBDIR="$4" ZLIB_INST="$5" ABI_CFLAGS="$6"
	local TRIPLE
	TRIPLE="$(abi_to_triple "$ABI")"

	local OPENSSH_SRC="$WORK_DIR/openssh-${OPENSSH_VERSION}"
	local SSHD_OUT="$OUT_DIR/$ABI/sshd"
	local SSHD_SESSION_OUT="$OUT_DIR/$ABI/sshd-session"
	local SSHD_AUTH_OUT="$OUT_DIR/$ABI/sshd-auth"
	local KEYGEN_OUT="$OUT_DIR/$ABI/ssh-keygen"
	local SFTP_OUT="$OUT_DIR/$ABI/sftp-server"

	if [ -f "$SSHD_OUT" ] && [ -f "$SSHD_SESSION_OUT" ] && [ -f "$SSHD_AUTH_OUT" ] && [ -f "$KEYGEN_OUT" ] && [ -f "$SFTP_OUT" ]; then
		log "[OPENSSH] Already built — skipping."
		return 0
	fi

	[ -d "$OPENSSH_SRC" ] || tar -xf "$SRC_DIR/openssh-${OPENSSH_VERSION}.tar.gz" -C "$WORK_DIR"

	log "[OPENSSH] Configuring for $TRIPLE..."
	cd "$OPENSSH_SRC"

	# Force bash as the default login shell, ignoring Android's /etc/passwd
	sed -i 's|copy->pw_shell = xstrdup(pw->pw_shell == NULL ? "" : pw->pw_shell);|copy->pw_shell = xstrdup("/data/adb/modules/ssh-ksu/system/bin/bash");|' misc.c

	# musl provides full POSIX libc — no stubs, no shims, no ac_cv overrides.
	# -Os:   size-optimised (smaller = faster mmap load on device)
	# -fno-lto is mandatory: GCC 15.x lto-wrapper has an ICE (get_token /
	# opts-common.cc:2175) when multiple parallel static-link jobs run at once.
	# Must be set in CFLAGS *before* ./configure so the feature probe doesn't
	# bake -flto into the generated Makefile.
    local OPENSSH_CFLAGS="${ABI_CFLAGS} \
        -Os -fno-lto -ffunction-sections -fdata-sections \
        -fstack-protector-strong \
        -Wno-deprecated-declarations \
        -DOPENSSL_SUPPRESS_DEPRECATED \
        -I$OPENSSL_INST/include \
        -I$ZLIB_INST/include"
    local OPENSSH_LDFLAGS="-L$OPENSSL_LIBDIR \
        -L$ZLIB_INST/lib \
        -static \
        -fno-lto \
        -Wl,--gc-sections"
    local OPENSSH_LIBS="-lssl -lcrypto -lz -ldl"

    CFLAGS="$OPENSSH_CFLAGS" LDFLAGS="-L. -L./openbsd-compat $OPENSSH_LDFLAGS" \
    ./configure \
        -C \
        --host="$TRIPLE" \
        --build="$(gcc -dumpmachine)" \
        --with-ssl-dir="$OPENSSL_INST" \
		--with-zlib="$ZLIB_INST" \
        --without-pam \
        --without-shadow \
        --without-bsd-auth \
        --without-kerberos5 \
        --without-libedit \
        --without-selinux \
        --disable-strip \
        --disable-lastlog \
        --disable-utmp \
        --disable-utmpx \
        --disable-wtmp \
        --disable-wtmpx \
        --disable-pututxline \
        --libexecdir=/system/bin \
        --with-privsep-user=root \
        --with-privsep-path=/dev/empty \
        --with-sandbox=no

    log "[OPENSSH] Building sshd, sshd-session, sshd-auth, ssh-keygen, sftp-server (jobs=$MAKE_JOBS)..."
    make -j"$MAKE_JOBS" $MAKE_V sshd sshd-session sshd-auth ssh-keygen sftp-server \
        CFLAGS="$OPENSSH_CFLAGS" \
        LDFLAGS="-L. -L./openbsd-compat $OPENSSH_LDFLAGS" \
        LIBS="$OPENSSH_LIBS"

	"$STRIP" --strip-all sshd sshd-session sshd-auth ssh-keygen sftp-server 2>/dev/null || true
	cp sshd "$SSHD_OUT"
	cp sshd-session "$SSHD_SESSION_OUT"
	cp sshd-auth "$SSHD_AUTH_OUT"
	cp ssh-keygen "$KEYGEN_OUT"
	cp sftp-server "$SFTP_OUT"

	log "[OPENSSH] sshd:         $(du -sh "$SSHD_OUT" | cut -f1)"
	log "[OPENSSH] sshd-session: $(du -sh "$SSHD_SESSION_OUT" | cut -f1)"
	log "[OPENSSH] sshd-auth:    $(du -sh "$SSHD_AUTH_OUT" | cut -f1)"
	log "[OPENSSH] ssh-keygen:   $(du -sh "$KEYGEN_OUT" | cut -f1)"
	log "[OPENSSH] sftp-server:  $(du -sh "$SFTP_OUT" | cut -f1)"
	cd "$SCRIPT_DIR"
}

# =============================================================================
#  STAGE 5 — rsync
# =============================================================================
build_rsync() {
    local ABI="$1" WORK_DIR="$2" POPT_INST="$3" ABI_CFLAGS="$4"
	local TRIPLE
	TRIPLE="$(abi_to_triple "$ABI")"

	local RSYNC_SRC="$WORK_DIR/rsync-${RSYNC_VERSION}"
	local RSYNC_OUT="$OUT_DIR/$ABI/rsync"

	if [ -f "$RSYNC_OUT" ]; then
		log "[RSYNC]  Already built — skipping."
		return 0
	fi

	[ -d "$RSYNC_SRC" ] || tar -xf "$SRC_DIR/rsync-${RSYNC_VERSION}.tar.gz" -C "$WORK_DIR"

	log "[RSYNC]  Configuring for $TRIPLE..."
	cd "$RSYNC_SRC"

    local RSYNC_CFLAGS="${ABI_CFLAGS} \
        -Os -ffunction-sections -fdata-sections \
        -fstack-protector-strong \
        -I$POPT_INST/include \
        -I./zlib"
    local RSYNC_LDFLAGS="-static -Wl,--gc-sections -L$POPT_INST/lib"

	CPPFLAGS="-I$POPT_INST/include" \
    LDFLAGS="-L$POPT_INST/lib -static" \
    ./configure \
        -C \
        --host="$TRIPLE" \
        --build="$(gcc -dumpmachine)" \
        --with-included-popt=no \
        --with-included-zlib=yes \
        --disable-acl-support \
        --disable-xattr-support \
        --disable-iconv \
        --disable-md2man \
        --disable-simd \
		--disable-roll-simd \
        --disable-openssl \
        --disable-xxhash \
        --disable-zstd \
        --disable-lz4 \
        rsync_cv_can_hardlink_special=no \
        rsync_cv_can_hardlink_symlink=no

	log "[RSYNC]  Building (jobs=$MAKE_JOBS)..."
    make -j"$MAKE_JOBS" $MAKE_V rsync \
        CFLAGS="$RSYNC_CFLAGS" \
        LDFLAGS="$RSYNC_LDFLAGS"

	"$STRIP" --strip-all rsync 2>/dev/null || true
	cp rsync "$RSYNC_OUT"

	log "[RSYNC]  rsync: $(du -sh "$RSYNC_OUT" | cut -f1)"
	cd "$SCRIPT_DIR"
}

# =============================================================================
#  STAGE 6 — bash (interactive login shell for SSH sessions)
#  --without-bash-malloc: Android's /proc/sys/vm layout makes sbrk unreliable;
#  using the system allocator (musl's) is safer and smaller.
#  --disable-nls: strips locale/gettext deps, ~200 KB saving.
#  --without-curses: no readline/terminfo needed for a minimal login shell.
# =============================================================================
# =============================================================================
#  STAGE 5.5 — ncurses (static libncurses, for bash readline)
# =============================================================================
build_ncurses() {
    local ABI="$1" WORK_DIR="$2" NCURSES_INST="$3" ABI_CFLAGS="$4"
    local TRIPLE
    TRIPLE="$(abi_to_triple "$ABI")"

    if [ -f "$NCURSES_INST/lib/libncurses.a" ] || [ -f "$NCURSES_INST/lib/libncursesw.a" ]; then
        log "[NCURSES] Already built — skipping."
        return 0
    fi

    local NCURSES_SRC="$WORK_DIR/ncurses-${NCURSES_VERSION}"
    [ -d "$NCURSES_SRC" ] || tar -xf "$SRC_DIR/ncurses-${NCURSES_VERSION}.tar.gz" -C "$WORK_DIR"

    log "[NCURSES] Configuring for $TRIPLE..."
    cd "$NCURSES_SRC"

    CFLAGS="${ABI_CFLAGS} -Os -ffunction-sections -fdata-sections -fstack-protector-strong" \
    LDFLAGS="-static" \
    ./configure \
        -C \
        --host="$TRIPLE" \
        --build="$(gcc -dumpmachine)" \
        --prefix="$NCURSES_INST" \
        --disable-shared \
        --enable-static \
        --without-ada \
        --without-tests \
        --without-debug \
        --without-cxx-binding \
        --without-progs \
        --enable-widec \
        --with-normal \
        --enable-pc-files \
        --with-pkg-config-libdir="$NCURSES_INST/lib/pkgconfig"

    log "[NCURSES] Building..."
    make -j"$MAKE_JOBS" $MAKE_V
    make $MAKE_V install

    log "[NCURSES] libncursesw.a: $(du -sh "$NCURSES_INST/lib/libncursesw.a" | cut -f1)"
    cd "$SCRIPT_DIR"
}

# =============================================================================
#  STAGE 6 — bash (interactive login shell for SSH sessions)
#  --without-bash-malloc: Android's /proc/sys/vm layout makes sbrk unreliable;
#  using the system allocator (musl's) is safer and smaller.
#  --disable-nls: strips locale/gettext deps, ~200 KB saving.
#  --without-curses: no readline/terminfo needed for a minimal login shell.
# =============================================================================
build_bash() {
	local ABI="$1" WORK_DIR="$2" NCURSES_INST="$3" ABI_CFLAGS="$4"
	local TRIPLE
	TRIPLE="$(abi_to_triple "$ABI")"

	local BASH_SRC="$WORK_DIR/bash-${BASH_VERSION}"
	local BASH_OUT="$OUT_DIR/$ABI/bash"

	if [ -f "$BASH_OUT" ]; then
		log "[BASH]   Already built — skipping."
		return 0
	fi

	[ -d "$BASH_SRC" ] || tar -xf "$SRC_DIR/bash-${BASH_VERSION}.tar.gz" -C "$WORK_DIR"

	log "[BASH]   Configuring for $TRIPLE with curses..."
	cd "$BASH_SRC"

	CFLAGS="${ABI_CFLAGS} -Os -ffunction-sections -fdata-sections -fstack-protector-strong -std=gnu89 -Wno-implicit-function-declaration -Wno-int-conversion -Wno-incompatible-pointer-types -I$NCURSES_INST/include -I$NCURSES_INST/include/ncursesw" \
	CC_FOR_BUILD="gcc -std=gnu89 -Wno-implicit-function-declaration -Wno-int-conversion -Wno-incompatible-pointer-types" \
	LDFLAGS="-static -Wl,--gc-sections -L$NCURSES_INST/lib" \
	./configure \
		-C \
		--host="$TRIPLE" \
		--build="$(gcc -dumpmachine)" \
		--without-bash-malloc \
		--disable-nls \
		--disable-rpath \
		--with-curses \
		--prefix=/system

	log "[BASH]   Building (jobs=$MAKE_JOBS)..."
	make -j"$MAKE_JOBS" $MAKE_V

	"$STRIP" --strip-all bash 2>/dev/null || true
	cp bash "$BASH_OUT"

	log "[BASH]   bash: $(du -sh "$BASH_OUT" | cut -f1)"
	cd "$SCRIPT_DIR"
}

# =============================================================================
#  ENTRY POINT
# =============================================================================
ABIS=()
case "${1:-all}" in
all) ABIS=(arm64-v8a x86_64) ;;
arm64) ABIS=(arm64-v8a) ;;
x86_64) ABIS=(x86_64) ;;
clean)
    log "Cleaning build artefacts..."
    [ -d "$BUILD_DIR" ] && chmod -R u+w "$BUILD_DIR" 2>/dev/null || true
    [ -d "$OUT_DIR" ] && chmod -R u+w "$OUT_DIR" 2>/dev/null || true
    rm -rf "$BUILD_DIR/arm64-v8a" "$BUILD_DIR/x86_64" "$OUT_DIR"
    log "Done."
    exit 0
    ;;
cleanall)
    log "Purging all local builds, config caches, and toolchain artifacts..."
    rm -rf .build/ out/ release/ config.cache config.status build/distcc.env
    if command -v ccache >/dev/null 2>&1; then
        ccache -C
    fi
    log "Done."
    exit 0
    ;;
*)
    echo "Usage: $0 {all|arm64|x86_64|clean|cleanall}"
    exit 1
    ;;
esac

for ABI in "${ABIS[@]}"; do
	build_for_abi "$ABI"
done

echo ""
log "Build complete. Binaries in $OUT_DIR/"
ls -lhR "$OUT_DIR/"

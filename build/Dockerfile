# =============================================================================
# Dockerfile — ssh-ksu cross-compilation environment
# =============================================================================
# Builds a reproducible Linux environment with:
#   - Android NDK r27d
#   - All build-time dependencies (perl, autoconf, make, etc.)
#
# Usage (from the ssh-ksu/ root, on Windows with Docker Desktop):
#   docker build -t ssh-ksu-builder -f build/Dockerfile .
#   docker run --rm -v "${PWD}:/workspace" ssh-ksu-builder bash build/build.sh all
#
# On Windows PowerShell, replace ${PWD} with ${PWD}:
#   docker run --rm -v "${PWD}:/workspace" ssh-ksu-builder bash build/build.sh all
# =============================================================================

FROM ubuntu:24.04

# ── System packages ─────────────────────────────────────────────────────────
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        make \
        autoconf \
        automake \
        libtool \
        perl \
        curl \
        wget \
        xz-utils \
        unzip \
        zip \
        patch \
        file \
        binutils \
        ca-certificates \
        python3 \
        git \
    && rm -rf /var/lib/apt/lists/*

# ── Android NDK r27d ────────────────────────────────────────────────────────
ENV NDK_VERSION=r27d
ENV ANDROID_NDK_HOME=/opt/android-ndk/android-ndk-${NDK_VERSION}

RUN mkdir -p /opt/android-ndk && \
    curl -fsSL \
        "https://dl.google.com/android/repository/android-ndk-${NDK_VERSION}-linux.zip" \
        -o /tmp/ndk.zip && \
    unzip -q /tmp/ndk.zip -d /opt/android-ndk && \
    rm /tmp/ndk.zip && \
    echo "NDK installed at: $ANDROID_NDK_HOME"

# ── Verify NDK ──────────────────────────────────────────────────────────────
RUN test -f "$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" || \
    { echo "NDK verification failed"; exit 1; }

# ── Working directory ───────────────────────────────────────────────────────
WORKDIR /workspace

# ── Default command (override with: docker run ... bash build/build.sh arm64)
CMD ["bash", "build/build.sh", "all"]

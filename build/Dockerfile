# =============================================================================
# Dockerfile — ssh-ksu cross-compilation environment (Hardened & Optimized)
# =============================================================================
# Builds a reproducible Linux environment with:
#   - Build-time dependencies (ccache, make, autoconf, perl, etc.)
#   - Fully pruned unused Android NDK
#   - Non-root unprivileged container safety
#
# Usage (from the ssh-ksu/ root):
#   docker build -t ssh-ksu-builder -f build/Dockerfile .
#   docker run --rm -v "${PWD}:/workspace" ssh-ksu-builder bash build/build.sh all
# =============================================================================

FROM ubuntu:24.04

# Define unprivileged builder user to avoid root privileges
ARG USER_NAME=builder
ARG USER_UID=1000
ARG USER_GID=1000

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
        ccache \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Set up non-root user and workspace directory
RUN groupadd -g ${USER_GID} ${USER_NAME} \
    && useradd -u ${USER_UID} -g ${USER_GID} -m -s /bin/bash ${USER_NAME} \
    && mkdir -p /workspace \
    && chown -R ${USER_NAME}:${USER_NAME} /workspace

USER ${USER_NAME}

# Set up compiler cache environment variables
ENV CCACHE_DIR=/home/${USER_NAME}/.cache/ccache
RUN mkdir -p ${CCACHE_DIR}

# ── Working directory ───────────────────────────────────────────────────────
WORKDIR /workspace

# ── Default command (override with: docker run ... bash build/build.sh arm64)
CMD ["bash", "build/build.sh", "all"]

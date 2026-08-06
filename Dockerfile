# =============================================================
# AmneziaWG kernel module builder for ASUS GT-AX11000
# Merlin 388.11 | Kernel 4.1.51 | aarch64
# =============================================================
FROM --platform=linux/amd64 ubuntu:20.04 AS builder

ARG DEBIAN_FRONTEND=noninteractive
ARG MERLIN_TAG=3004.388.11

# --- Build dependencies ---
# libc6-i386: toolchain binaries are 32-bit x86
RUN dpkg --add-architecture i386 && \
    apt-get update && apt-get install -y \
    git build-essential bc libncurses5-dev \
    libelf-dev libssl-dev wget curl file \
    gawk flex bison cpio rsync unzip xz-utils \
    libc6-i386 lib32stdc++6 lib32z1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# =============================================================
# 1. Broadcom HND aarch64 toolchain (sparse checkout)
# =============================================================
RUN git clone --depth 1 --filter=blob:none \
        https://github.com/RMerl/am-toolchains.git && \
    cd am-toolchains && \
    git sparse-checkout init --cone && \
    git sparse-checkout set \
        brcm-arm-hnd/crosstools-aarch64-gcc-5.5-linux-4.1-glibc-2.26-binutils-2.28.1

ENV TOOLCHAIN=/build/am-toolchains/brcm-arm-hnd/crosstools-aarch64-gcc-5.5-linux-4.1-glibc-2.26-binutils-2.28.1
ENV PATH="${TOOLCHAIN}/usr/bin:${PATH}"
ENV LD_LIBRARY_PATH="${TOOLCHAIN}/usr/lib:${TOOLCHAIN}/lib:/usr/lib/x86_64-linux-gnu"
ENV CROSS_COMPILE=aarch64-buildroot-linux-gnu-
ENV ARCH=arm64

# Verify toolchain is functional
RUN aarch64-buildroot-linux-gnu-gcc --version

# =============================================================
# 2. Kernel source from Merlin (Broadcom HND patched 4.1.x)
#    Vanilla kernel.org source has different internal structures
#    from Broadcom's modified kernel, causing module crashes.
# =============================================================
COPY merlin-kernel /build/kernel-src

ENV KERNEL_SRC=/build/kernel-src

# =============================================================
# 3. Kernel config (extracted from router /proc/config.gz)
# =============================================================
COPY kernel.config ${KERNEL_SRC}/.config

# Cross-compiler runtime dependencies (libmpc for cc1)
# Download .deb directly to avoid apt-get update issues
RUN curl -L http://security.ubuntu.com/ubuntu/pool/main/m/mpclib3/libmpc3_1.1.0-1_amd64.deb -o /tmp/libmpc3.deb && \
    dpkg -i /tmp/libmpc3.deb && rm /tmp/libmpc3.deb

# Prepare kernel build tree for out-of-tree modules
# Fix Broadcom-specific references that point outside the kernel tree
RUN cd ${KERNEL_SRC} && \
    sed -i 's|^include ../../.config|BUILD_NAME=GT-AX11000|' Makefile && \
    rm -rf kernel/configs && \
    for d in net/netfilter/fltr net/sched/sch_cake; do \
        rm -f "$d"; mkdir -p "$d"; touch "$d/Kconfig" "$d/Makefile"; \
    done && \
    mkdir -p ../../bcmdrivers && touch ../../bcmdrivers/Kconfig.autogen && \
    touch Module.symvers && \
    yes "" | make ARCH=arm64 CROSS_COMPILE=${CROSS_COMPILE} oldconfig && \
    make ARCH=arm64 CROSS_COMPILE=${CROSS_COMPILE} modules_prepare && \
    cat include/config/kernel.release

# =============================================================
# 4. Build AmneziaWG kernel module (amneziawg.ko)
# =============================================================
RUN git clone --depth 1 --branch v1.0.20260322 \
        https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git

# Build out-of-tree module against Merlin kernel
RUN cd amneziawg-linux-kernel-module/src && \
    make ARCH=arm64 \
         CROSS_COMPILE=${CROSS_COMPILE} \
         KERNELDIR=${KERNEL_SRC} \
         BUILD_NAME=GT-AX11000 && \
    echo "--- Module info ---" && \
    file amneziawg.ko && \
    strings amneziawg.ko | grep "vermagic="

# =============================================================
# 5. Build AmneziaWG tools (awg — аналог wg)
# =============================================================
RUN git clone --depth 1 --branch v3.0.20260805 \
        https://github.com/amnezia-vpn/amneziawg-tools.git

RUN cd amneziawg-tools/src && \
    make CC=${CROSS_COMPILE}gcc \
         LD=${CROSS_COMPILE}ld \
         AR=${CROSS_COMPILE}ar \
         PLATFORM_CFLAGS="" && \
    echo "--- Tools info ---" && \
    ls -la wg awg 2>/dev/null; true

# =============================================================
# 6. Collect artifacts
# =============================================================
RUN mkdir -p /output && \
    cp amneziawg-linux-kernel-module/src/amneziawg.ko /output/ && \
    # amneziawg-tools may produce "wg" or "awg" depending on version
    (cp amneziawg-tools/src/awg /output/awg 2>/dev/null || \
     cp amneziawg-tools/src/wg  /output/awg) && \
    chmod +x /output/awg && \
    echo "============================================" && \
    echo "  BUILD COMPLETE" && \
    echo "============================================" && \
    echo "Module:" && \
    file /output/amneziawg.ko && \
    strings /output/amneziawg.ko | grep "vermagic=" && \
    echo "Tool:" && \
    file /output/awg && \
    ls -lh /output/

# --- Export stage (docker build --output) ---
FROM scratch AS export
COPY --from=builder /output/ /

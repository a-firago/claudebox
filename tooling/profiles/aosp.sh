#!/bin/bash
# DESCRIPTION: AOSP Build Environment (Android Open Source Project build dependencies)

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "[aosp] Installing AOSP build dependencies..."
apt-get update
apt-get install -y --no-install-recommends \
    git-core \
    gnupg \
    flex \
    bison \
    build-essential \
    zip \
    curl \
    zlib1g-dev \
    libc6-dev-i386 \
    x11proto-core-dev \
    libx11-dev \
    lib32z1-dev \
    libgl1-mesa-dev \
    libxml2-utils \
    xsltproc \
    unzip \
    fontconfig \
    gcc-aarch64-linux-gnu \
    openssl \
    libssl-dev \
    device-tree-compiler \
    rsync \
    bc \
    libncurses5 \
    uuid \
    uuid-dev  \
    liblz-dev \
    liblzo2-dev \
    lzop \
    u-boot-tools \
    mtd-utils \
    android-sdk-build-tools \
    android-sdk-platform-tools \
    gdisk \
    liblz4-tool \
    m4 \
    cpio \
    python-is-python3

apt-get clean

echo "[aosp] Installation complete."

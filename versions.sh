# shellcheck shell=bash disable=SC2034 # Sourced by the other scripts.
# Pinned inputs for build.sh. Every download is checked against its SHA-256
# (git sources against their commit) before it's used.

FFMPEG_VERSION=8.1.3
# Bump when the build changes but FFmpeg doesn't. Releases are tagged
# $FFMPEG_VERSION-r$REVISION.
REVISION=2

FFMPEG_URL=https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz
FFMPEG_SHA256=7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3

# Software VP9 encoder: the conversion fallback where there's no usable
# hardware encoder (Linux, Windows without Media Foundation).
LIBVPX_VERSION=1.17.0
LIBVPX_URL=https://github.com/webmproject/libvpx/archive/refs/tags/v$LIBVPX_VERSION.tar.gz
LIBVPX_SHA256=1020f184046187baa2985dbde38e0691f49c44088bca7a1842b0236c6081dc0a

ZLIB_VERSION=1.3.2
ZLIB_URL=https://github.com/madler/zlib/releases/download/v$ZLIB_VERSION/zlib-$ZLIB_VERSION.tar.gz
ZLIB_SHA256=bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16

# NVENC and AMF are header-only; FFmpeg loads the drivers' DLLs at runtime.
# 12.1 is the oldest SDK FFmpeg accepts, so it needs the oldest NVIDIA driver.
NVCODEC_VERSION=12.1.14.1
NVCODEC_URL=https://github.com/FFmpeg/nv-codec-headers/archive/refs/tags/n$NVCODEC_VERSION.tar.gz
NVCODEC_SHA256=f40c8a27417eb2688412da32985e382e811196311c4d103d1fcaafad2876cfc1

AMF_VERSION=1.5.3
AMF_REPO=https://github.com/GPUOpen-LibrariesAndSDKs/AMF.git
AMF_COMMIT=57ee0cfb0e1a08d9041f77435653794c1b012be0

# Toolchains and build images.
LLVM_MINGW_VERSION=20261020
LLVM_MINGW_SHA256_x86_64=55064b60b991a1e1e8090b8c2f84e82b22cfe5903d12c159d65064cf5e8ae335
LLVM_MINGW_SHA256_aarch64=ca16bb0f4f485876496fa46ad8d353c525eba57d0cf9e9e49ec1738fe4810151
ALPINE_IMAGE=alpine:3.24.3
UBUNTU_IMAGE=ubuntu:24.04
MACOS_MIN_VERSION=11.0

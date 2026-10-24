#!/usr/bin/env bash
# Builds the minimal LGPL FFmpeg that Rimlo downloads on demand.
#
#   ./build.sh <target> [work-dir]
#
# Targets are named after Node's process.platform-process.arch:
#
#   darwin-arm64, darwin-x64   natively, on a Mac of that architecture
#   linux-x64, linux-arm64     static (musl) in an Alpine container, via Docker
#   win32-x64, win32-arm64     cross-compiled with llvm-mingw in an Ubuntu container, via Docker
#
# Every decoder, demuxer and parser is kept, so any file can be imported.
# Encoders are limited to what Rimlo uses: AAC, PCM and ProRes for exports,
# and H.264 or VP9 for converting media it can't play. No GPL or non-free
# code, no network protocols, no ffprobe or ffplay.
#
# Writes <work-dir>/dist/ffmpeg-<version>-r<revision>-<target>.tar.xz (.zip on Windows).
#
# shellcheck disable=SC2054 # Commas in FFmpeg's option values aren't array separators.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
. "$here/versions.sh"

target=${1:?usage: build.sh <target> [work-dir]}
work=${2:-$here/work}
os=${target%-*}
arch=${target#*-}
name=ffmpeg-$FFMPEG_VERSION-r$REVISION-$target

die() {
  echo "build.sh: $*" >&2
  exit 1
}

case $target in
  darwin-arm64 | darwin-x64 | linux-x64 | linux-arm64 | win32-x64 | win32-arm64) ;;
  *) die "unknown target $target" ;;
esac
mkdir -p "$work"
work=$(cd "$work" && pwd)

# Linux and Windows build in pinned containers, so CI and a laptop build the same thing.
if [ "$os" != darwin ] && [ -z "${IN_BUILD_CONTAINER:-}" ]; then
  if [ "$os" = linux ]; then
    image=$ALPINE_IMAGE
    platform=linux/${arch/x64/amd64}
    setup="apk add --no-cache bash build-base curl diffutils linux-headers perl pkgconf tar xz"
    [ "$arch" = x64 ] && setup+=" nasm"
  else
    image=$UBUNTU_IMAGE
    platform= # The host's own: llvm-mingw targets both architectures from either.
    setup="apt-get update -qq && apt-get install -qq -y --no-install-recommends"
    setup+=" ca-certificates curl gcc git libc6-dev make nasm perl pkg-config xz-utils zip >/dev/null"
  fi
  # Compile in the container's own filesystem; only the cache and results go to the mount.
  exec docker run --rm ${platform:+--platform "$platform"} -e IN_BUILD_CONTAINER=1 -e BUILD_ROOT=/build \
    -v "$here:/src:ro" -v "$work:/work" "$image" sh -c "$setup && /src/build.sh $target /work"
fi

jobs=$(getconf _NPROCESSORS_ONLN)
root=${BUILD_ROOT:-$work}/$target
src=$root/src
prefix=$root/prefix
cache=$work/cache
dist=$work/dist
rm -rf "$root"
mkdir -p "$src" "$prefix/include" "$prefix/lib/pkgconfig" "$cache" "$dist"
# Only what this script builds; never the host's libraries.
export PKG_CONFIG_LIBDIR=$prefix/lib/pkgconfig
unset PKG_CONFIG_PATH

sha256() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# Downloads a pinned file into the cache once, and refuses it unless its checksum matches.
fetch() { # url sha256 [file name]
  local file=$cache/${3:-${1##*/}}
  if [ ! -f "$file" ]; then
    curl -fsSL --retry 3 -o "$file.part" "$1"
    mv "$file.part" "$file"
  fi
  [ "$(sha256 "$file")" = "$2" ] || die "checksum mismatch for $1"
  echo "$file"
}

unpack() { # dir url sha256 [file name]
  local archive
  archive=$(fetch "$2" "$3" "${4:-}")
  mkdir -p "$src/$1"
  tar -xf "$archive" -C "$src/$1" --strip-components 1
}

cflags=
ldflags=
case $os in
  darwin)
    [ "$(uname -s)" = Darwin ] || die "$target builds on macOS"
    [ "$(uname -m)" = "${arch/x64/x86_64}" ] || die "$target builds on a Mac of that architecture"
    [ "$arch" = arm64 ] || command -v nasm >/dev/null || die "needs nasm (brew install nasm)"
    CC=clang STRIP=strip
    cflags+=" -mmacosx-version-min=$MACOS_MIN_VERSION"
    ldflags+=" -mmacosx-version-min=$MACOS_MIN_VERSION"
    ;;
  linux)
    CC=gcc CXX=g++ AR=ar NM=nm STRIP=strip
    # musl's default thread stack (128 KiB) is too small for some decoders.
    ldflags+=" -static -Wl,-z,stack-size=2097152"
    ;;
  win32)
    host=$(uname -m)
    toolchain=llvm-mingw-$LLVM_MINGW_VERSION-ucrt-ubuntu-22.04-$host
    sum=LLVM_MINGW_SHA256_$host
    archive=$(fetch "https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW_VERSION/$toolchain.tar.xz" "${!sum}")
    tar -xf "$archive" -C "$root"
    export PATH=$root/$toolchain/bin:$PATH
    triple=${arch/x64/x86_64}
    triple=${triple/arm64/aarch64}-w64-mingw32
    CC=$triple-clang CXX=$triple-clang++ AR=$triple-ar NM=$triple-nm STRIP=$triple-strip
    ldflags+=" -static"
    ;;
esac

# zlib (PNG, TIFF, compressed MOV headers…) as a static library, from its sources directly.
build_zlib() {
  unpack zlib "$ZLIB_URL" "$ZLIB_SHA256"
  (
    cd "$src/zlib"
    sed -i 's/^#if.* HAVE_UNISTD_H.*/#if 1/' zconf.h # What zlib's configure does on every target here.
    # shellcheck disable=SC2086 # $cflags is a list of flags.
    for file in *.c; do $CC -O2 $cflags -c "$file"; done
    $AR rcs "$prefix/lib/libz.a" ./*.o
    cp zlib.h zconf.h "$prefix/include/"
  )
}

# libvpx, encoder only: the VP9 fallback for converting media.
build_libvpx() {
  local platform as=()
  [ "$arch" = x64 ] && as=(--as=nasm)
  case $target in
    linux-x64) platform=x86_64-linux-gcc ;;
    linux-arm64) platform=arm64-linux-gcc ;;
    win32-x64) platform=x86_64-win64-gcc ;;
    win32-arm64) platform=arm64-win64-gcc ;;
  esac
  unpack libvpx "$LIBVPX_URL" "$LIBVPX_SHA256" "libvpx-$LIBVPX_VERSION.tar.gz"
  (
    cd "$src/libvpx"
    export CC CXX AR NM STRIP LD=$CC
    ./configure --target="$platform" --prefix="$prefix" \
      --enable-static --disable-shared --disable-examples --disable-tools --disable-docs \
      --disable-unit-tests --disable-vp8 --disable-vp9-decoder --disable-webm-io --disable-libyuv \
      "${as[@]}" &&
      make -j"$jobs" &&
      make install
  ) >"$root/libvpx.log" 2>&1 || {
    tail -n 40 "$root/libvpx.log"
    die "libvpx failed"
  }
}

# NVENC and AMF headers: FFmpeg loads the drivers' own DLLs at runtime.
install_nvenc() {
  unpack nv-codec-headers "$NVCODEC_URL" "$NVCODEC_SHA256" "nv-codec-headers-$NVCODEC_VERSION.tar.gz"
  make -C "$src/nv-codec-headers" install PREFIX="$prefix" >/dev/null
}

install_amf() {
  git clone -q --filter=blob:none --no-checkout --depth 1 --branch "v$AMF_VERSION" "$AMF_REPO" "$src/amf"
  git -C "$src/amf" sparse-checkout set --no-cone /LICENSE.txt /amf/public/include
  git -C "$src/amf" checkout -q
  [ "$(git -C "$src/amf" rev-parse HEAD)" = "$AMF_COMMIT" ] || die "AMF v$AMF_VERSION isn't commit $AMF_COMMIT"
  mkdir -p "$prefix/include/AMF"
  cp -R "$src/amf/amf/public/include/." "$prefix/include/AMF/"
}

encoders=aac,prores_ks,pcm_s16le,pcm_s24le,pcm_f32le,rawvideo,wrapped_avframe
config=()
case $os in
  darwin)
    config+=(
      --enable-videotoolbox --enable-audiotoolbox
      --enable-hwaccel=h264_videotoolbox,hevc_videotoolbox,prores_videotoolbox,vp9_videotoolbox
    )
    encoders+=,h264_videotoolbox,hevc_videotoolbox,prores_videotoolbox
    ;;
  linux)
    build_zlib
    build_libvpx
    config+=(--cc="$CC" --enable-libvpx --disable-decoder=libvpx_vp8,libvpx_vp9)
    encoders+=,libvpx_vp9
    ;;
  win32)
    build_zlib
    build_libvpx
    config+=(
      --enable-cross-compile --target-os=mingw32 --arch="${triple%%-*}" --cross-prefix="$triple-"
      --cc="$CC" --cxx="$CXX" --pkg-config=pkg-config
      --enable-mediafoundation --enable-d3d11va --enable-libvpx --disable-decoder=libvpx_vp8,libvpx_vp9
    )
    encoders+=,h264_mf,libvpx_vp9
    if [ "$arch" = x64 ]; then
      install_nvenc
      install_amf
      config+=(--enable-ffnvcodec --enable-nvenc --enable-amf)
      encoders+=,h264_nvenc,h264_amf
    fi
    ;;
esac

unpack ffmpeg "$FFMPEG_URL" "$FFMPEG_SHA256"
cd "$src/ffmpeg"
./configure \
  --prefix="$prefix" \
  --disable-everything --disable-autodetect --disable-doc --disable-debug \
  --disable-network --disable-programs --enable-ffmpeg \
  --enable-zlib \
  --enable-decoders --enable-demuxers --enable-parsers --enable-bsfs \
  --enable-protocol=file,pipe \
  --enable-muxer=mov,mp4,ipod,adts,null,rawvideo \
  --enable-filter=scale,format,aformat,aresample,anull,null,vflip,hflip,transpose,fps,setsar,setpts,asetpts,pad,crop,hwupload,hwdownload \
  --extra-cflags="$cflags -I$prefix/include" \
  --extra-ldflags="$ldflags -L$prefix/lib" \
  --pkg-config-flags=--static \
  "${config[@]}" \
  --enable-encoder="$encoders" >"$root/configure.log" || {
  tail -n 40 ffbuild/config.log
  die "FFmpeg configure failed"
}
grep -E '^(threading support|External libraries|Enabled encoders)' -A 4 "$root/configure.log" || true
make -j"$jobs" >"$root/make.log" 2>&1 || {
  tail -n 40 "$root/make.log"
  die "FFmpeg build failed"
}

exe=ffmpeg
[ "$os" = win32 ] && exe=ffmpeg.exe
stage=$root/stage
bin=$stage/bin/$exe
mkdir -p "$stage/bin" "$stage/licenses"
cp "$exe" "$bin"
$STRIP "$bin"

# The binary must run on a stock system: nothing beyond what the OS ships.
case $os in
  darwin)
    codesign --force --sign - "$bin" # Re-sign ad hoc after stripping; arm64 won't run it otherwise.
    extra=$(otool -L "$bin" | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/Library/)' || true)
    [ -z "$extra" ] || die "links libraries macOS doesn't ship: $extra"
    ;;
  linux)
    if readelf -d "$bin" | grep -q NEEDED; then die "isn't statically linked"; fi
    ;;
  win32)
    for dll in $("$triple-objdump" -p "$bin" | awk '/DLL Name:/ {print tolower($3)}'); do
      case $dll in
        api-ms-win-crt-*.dll | kernel32.dll | user32.dll | advapi32.dll | bcrypt.dll | ole32.dll | shell32.dll) ;;
        *) die "depends on $dll, which Windows doesn't ship" ;;
      esac
    done
    ;;
esac
if [ "$os" != win32 ]; then
  version=$("$bin" -hide_banner -version)
  echo "${version%%$'\n'*}"
fi

cp COPYING.LGPLv2.1 "$stage/LICENSE.txt"
bundled=
if [ -d "$src/zlib" ]; then
  cp "$src/zlib/LICENSE" "$stage/licenses/zlib.txt"
  bundled+="zlib $ZLIB_VERSION, "
fi
if [ -d "$src/libvpx" ]; then
  cp "$src/libvpx/LICENSE" "$stage/licenses/libvpx.txt"
  cp "$src/libvpx/PATENTS" "$stage/licenses/libvpx-patents.txt"
  bundled+="libvpx $LIBVPX_VERSION, "
fi
if [ -d "$src/nv-codec-headers" ]; then
  sed -n '/Copyright/,/SOFTWARE\./p' "$src/nv-codec-headers/include/ffnvcodec/nvEncodeAPI.h" >"$stage/licenses/nv-codec-headers.txt"
  bundled+="nv-codec-headers $NVCODEC_VERSION, "
fi
if [ -d "$src/amf" ]; then
  cp "$src/amf/LICENSE.txt" "$stage/licenses/amf.txt"
  bundled+="AMF headers $AMF_VERSION, "
fi

configuration=$(sed -n 's/^#define FFMPEG_CONFIGURATION "\(.*\)"$/\1/p' config.h)
cat >"$stage/README.txt" <<EOF
FFmpeg $FFMPEG_VERSION for Rimlo: $target, build $FFMPEG_VERSION-r$REVISION.

FFmpeg is licensed under the LGPL 2.1 or later (LICENSE.txt). This build has no
GPL or non-free components.
${bundled:+
Also included, with their licenses in licenses/: ${bundled%, }.
}
Source: $FFMPEG_URL
        (SHA-256 $FFMPEG_SHA256, also attached to the release)
Built by build.sh in https://github.com/rimlo-ai/ffmpeg-builds at tag $FFMPEG_VERSION-r$REVISION.

Configuration: $configuration
EOF

rm -f "$dist/$name".*
if [ "$os" = win32 ]; then
  (cd "$stage" && zip -qrX "$dist/$name.zip" .)
else
  tar -cJf "$dist/$name.tar.xz" -C "$stage" .
fi
for file in "$dist/$name".*; do
  echo "$(sha256 "$file")  $(wc -c <"$file" | tr -d ' ') bytes  ${file##*/}"
done

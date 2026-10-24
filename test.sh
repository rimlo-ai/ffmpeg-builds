#!/usr/bin/env bash
# Smoke-tests a build the way Rimlo uses it:
#
#   ./test.sh <path/to/ffmpeg>
#
# 1. ProRes export: raw RGBA frames and f32 PCM in, ProRes 422 and PCM .mov out.
# 2. Converting media Rimlo can't play: that .mov to H.264 or VP9 with AAC in an
#    MP4, using the first encoder that works here, tried in Rimlo's order.
# 3. AAC for exports where the OS has no AAC encoder: f32 PCM piped in, ADTS piped out.
#
# Then decodes every output, and checks the build is LGPL.
set -euo pipefail

ff=${1:?usage: test.sh <path/to/ffmpeg>}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "not ok - $*" >&2
  exit 1
}
ok() { echo "ok - $*"; }
run() { "$ff" -hide_banner -nostdin -v error -y "$@"; }

version=$("$ff" -hide_banner -version)
echo "${version%%$'\n'*}"
case $version in
  *--enable-gpl* | *--enable-nonfree*) fail "isn't an LGPL build" ;;
esac
ok "LGPL build"

encoders=$("$ff" -hide_banner -encoders)
has() { grep -q " $1 " <<<"$encoders"; }
required="aac prores_ks pcm_s16le"
case $(uname -s) in
  Darwin) required+=" h264_videotoolbox" ;;
  Linux) required+=" libvpx-vp9" ;;
  MINGW* | MSYS*) required+=" h264_mf" ;;
esac
for encoder in $required; do has "$encoder" || fail "missing encoder $encoder"; done
ok "has $required"

w=320 h=180
head -c $((w * h * 4 * 30)) /dev/urandom >"$tmp/frames.rgba"
# A 12 kHz square wave as stereo f32 (random bytes would contain NaNs): 1 MiB, ~2.7 s.
printf '\x00\x00\x00\x3f%.0s' 1 2 3 4 >"$tmp/audio.f32"
printf '\x00\x00\x00\xbf%.0s' 1 2 3 4 >>"$tmp/audio.f32"
for _ in $(seq 15); do
  cat "$tmp/audio.f32" "$tmp/audio.f32" >"$tmp/double" && mv "$tmp/double" "$tmp/audio.f32"
done

run -f rawvideo -pix_fmt rgba -s ${w}x$h -framerate 30 -i "$tmp/frames.rgba" \
  -f f32le -ar 48000 -ac 2 -i "$tmp/audio.f32" \
  -vf vflip -c:v prores_ks -profile:v 2 -pix_fmt yuv422p10le -vendor apl0 \
  -c:a pcm_s16le -f mov "$tmp/export.mov" || fail "ProRes export"
ok "ProRes export"

# Rimlo's candidates and arguments (src/main/ffmpeg/binary.ts there), in its order.
candidates=(
  "h264_videotoolbox|format=yuv420p|-allow_sw 1"
  "h264_nvenc|format=yuv420p|-preset p5"
  "h264_qsv|format=nv12|-preset medium"
  "h264_amf|format=yuv420p|-quality quality"
  "h264_mf|format=nv12|"
  "libopenh264|format=yuv420p|"
  "libvpx-vp9|format=yuv420p|-deadline realtime -cpu-used 8 -row-mt 1"
)
used=
for candidate in "${candidates[@]}"; do
  IFS='|' read -r encoder filter args <<<"$candidate"
  has "$encoder" || continue
  # shellcheck disable=SC2086 # $args is a list of arguments.
  if run -i "$tmp/export.mov" -map 0:v:0 -map '0:a:0?' \
    -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2,$filter" -c:v "$encoder" $args \
    -b:v 2000000 -g 30 -c:a aac -b:a 256k -movflags +faststart \
    -progress pipe:1 -nostats -f mp4 "$tmp/converted.mp4" >"$tmp/progress" 2>"$tmp/error"; then
    used=$encoder
    break
  fi
  echo "# $encoder doesn't work here: $(tail -n 1 "$tmp/error")"
done
[ -n "$used" ] || fail "no encoder can convert media"
grep -q '^progress=end' "$tmp/progress" || fail "no progress report"
ok "conversion with $used"

run -f f32le -ar 48000 -ac 2 -i pipe:0 -c:a aac -b:a 192k -f adts pipe:1 \
  <"$tmp/audio.f32" >"$tmp/audio.aac" || fail "AAC encode"
ok "AAC through pipes"

for file in export.mov converted.mp4 audio.aac; do
  run -i "$tmp/$file" -f null - || fail "decoding $file"
done
ok "every output decodes"

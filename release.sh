#!/usr/bin/env bash
# Prepares a release from the CI artifacts in <dist>: adds the FFmpeg source
# (the LGPL source offer), SHA256SUMS and manifest.json, and writes the notes.
#
#   ./release.sh <dist> <notes-file>
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
. "$here/versions.sh"

dist=$(cd "${1:?usage: release.sh <dist> <notes-file>}" && pwd)
notes=${2:?usage: release.sh <dist> <notes-file>}
tag=$FFMPEG_VERSION-r$REVISION
repo=${GITHUB_REPOSITORY:-rimlo-ai/ffmpeg-builds}
base=https://github.com/$repo/releases/download/$tag

if [ -n "${GITHUB_REF_NAME:-}" ] && [ "$GITHUB_REF_NAME" != "$tag" ]; then
  echo "release.sh: tag $GITHUB_REF_NAME doesn't match versions.sh ($tag)" >&2
  exit 1
fi

source=$dist/ffmpeg-$FFMPEG_VERSION.tar.xz
curl -fsSL --retry 3 -o "$source" "$FFMPEG_URL"
[ "$(sha256sum "$source" | cut -d' ' -f1)" = "$FFMPEG_SHA256" ] || {
  echo "release.sh: FFmpeg source checksum mismatch" >&2
  exit 1
}

cd "$dist"
sha256sum ffmpeg-* >SHA256SUMS

python3 - "$tag" "$base" "$FFMPEG_VERSION" "$REVISION" >manifest.json <<'EOF'
import hashlib, json, os, sys

tag, base, version, revision = sys.argv[1:]
builds = {}
for file in sorted(os.listdir('.')):
    prefix = f'ffmpeg-{tag}-'
    if not file.startswith(prefix):
        continue
    target, ext = file[len(prefix):].split('.', 1)
    data = open(file, 'rb').read()
    builds[target] = {
        'url': f'{base}/{file}',
        'sha256': hashlib.sha256(data).hexdigest(),
        'size': len(data),
        'format': ext,
        'binary': 'bin/ffmpeg.exe' if target.startswith('win32') else 'bin/ffmpeg',
    }
json.dump({'version': version, 'revision': int(revision), 'tag': tag, 'builds': builds}, sys.stdout, indent=2)
print()
EOF

python3 - "$repo" "$FFMPEG_VERSION" "$REVISION" >"$notes" <<'EOF'
import json, sys

repo, version, revision = sys.argv[1:]
print(f'FFmpeg {version} for [Rimlo](https://rimlo.app), build r{revision}. '
      'LGPL 2.1 or later, with no GPL or non-free components.')
print()
print('| Target | Size | SHA-256 |')
print('| --- | --- | --- |')
for target, build in json.load(open('manifest.json'))['builds'].items():
    print(f"| {target} | {build['size'] / 1e6:.1f} MB | `{build['sha256']}` |")
print()
print(f'Built and tested by [CI](https://github.com/{repo}/actions) from the scripts at this tag. '
      'Every archive has a build provenance attestation: '
      f'`gh attestation verify <file> --repo {repo}`.')
print()
print(f'The FFmpeg source they were built from is attached as `ffmpeg-{version}.tar.xz`.')
EOF

cat SHA256SUMS

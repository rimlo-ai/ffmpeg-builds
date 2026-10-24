# FFmpeg builds for Rimlo

Minimal LGPL builds of [FFmpeg](https://ffmpeg.org) that [Rimlo](https://rimlo.app) downloads on demand as its optional "media converter". Rimlo does almost everything with the codecs built into Chromium. FFmpeg covers the rest:

- **Importing** formats the machine can't decode (ProRes, MPEG-2, AC-3, WMV, …). These are converted once into an H.264 or VP9 copy that Rimlo can play.
- **Exporting ProRes.**
- **Encoding AAC** where the OS has no AAC encoder (some Linux systems).

Each build keeps every decoder, demuxer and parser, but only the encoders Rimlo uses. It has no network protocols and no `ffprobe` or `ffplay`. That makes it a few MB rather than the 50–80 MB of a general-purpose build.

## Builds

Targets use Node's `process.platform-process.arch` names.

| Target | Built | Video encoders for conversion | Runs on |
| --- | --- | --- | --- |
| `darwin-arm64` | natively on macOS | VideoToolbox | macOS 11+ |
| `darwin-x64` | natively on macOS | VideoToolbox | macOS 11+ |
| `linux-x64` | Alpine container, static (musl) | libvpx VP9 | any distribution |
| `linux-arm64` | Alpine container, static (musl) | libvpx VP9 | any distribution |
| `win32-x64` | llvm-mingw cross build | NVENC, AMF, Media Foundation, libvpx VP9 | Windows 10+ |
| `win32-arm64` | llvm-mingw cross build | Media Foundation, libvpx VP9 | Windows 11 |

Every build also has `aac`, `prores_ks` and PCM encoders. The binaries depend only on libraries the OS ships. Hardware encoders are loaded at runtime, so a build still runs on machines without them.

## Licensing

FFmpeg is built without `--enable-gpl` or `--enable-nonfree`, so each build is LGPL 2.1 or later. It is distributed as a separate executable that users can replace (Rimlo lets them choose their own FFmpeg). Each archive contains:

- FFmpeg's license.
- The licenses of the bundled libraries: libvpx (BSD), zlib, and the NVENC and AMF headers (MIT).
- A README with the exact source and configuration.

Every release attaches the FFmpeg source tarball it was built from.

## Building

`versions.sh` pins every input, each checked by SHA-256 or commit:

- FFmpeg, libvpx and zlib.
- The NVENC and AMF headers.
- The llvm-mingw toolchain and the container images.

```sh
./build.sh <target> [work-dir]   # → <work-dir>/dist/ffmpeg-<version>-r<revision>-<target>.tar.xz (.zip on Windows)
./test.sh <path/to/ffmpeg>       # smoke test: the conversions Rimlo runs
```

Linux and Windows targets build in Docker on any host. macOS targets build on a Mac of the same architecture, and Intel needs `nasm` (`brew install nasm`).

## Releasing

CI (`.github/workflows/build.yml`) builds every target on each push and tests each build on the OS it's for. Releases come only from CI:

1. Change `versions.sh`, either bumping `REVISION` or setting a new FFmpeg version with `REVISION=1`.
2. Push, and wait for CI to pass.
3. Tag the commit `<FFMPEG_VERSION>-r<REVISION>` (for example `8.1.3-r1`) and push the tag.

CI then publishes the release with:

- The archives.
- The FFmpeg source.
- `SHA256SUMS`.
- A `manifest.json` that Rimlo's pinned build list (`src/main/ffmpeg/builds.ts`) is updated from.
- A build provenance attestation for each archive.

# ffmpeg-hermetic

Static [FFmpeg] plus 40+ codec, filter and hardware libraries, cross-compiled for Linux, Windows
and macOS from unmodified upstream sources. The only thing you need is [Zig].

- **One build graph.** A single `zig build` compiles every library and FFmpeg itself, for any
  supported target, from any host. No configure, autotools, CMake, meson, perl or system packages.
- **Pinned, unpatched sources.** Every upstream source is a hash-pinned dependency in
  `build.zig.zon`, used exactly as released.
- **Plain C output.** Static libraries, headers and a link manifest, ready for any toolchain that
  links C: a C or C++ build, a Rust `build.rs`, cgo, and so on.

## Quick start

Requires [Zig 0.17.0][zig-download]. Everything else, nasm included, is built from source.

```sh
# LGPL build, runs on glibc 2.17+
zig build -Dtarget=x86_64-linux-gnu.2.17 --release=fast

# GPL build (adds x264, x265, xvidcore, vidstab, rubberband)
zig build -Dtarget=x86_64-linux-gnu.2.17 --release=fast -Dgpl

# Pack a self-describing bundle and link-test it
zig build -Dtarget=x86_64-linux-gnu.2.17 --release=fast bundle bundle-check
```

Omitting `--release` gives a Debug build.

## Targets

| Target | Status |
| --- | --- |
| `x86_64-linux-gnu.2.17` | LGPL and GPL; FATE runs in CI |
| `aarch64-linux-gnu.2.17` | LGPL and GPL; NEON, plus SVE/SVE2/dotprod/i8mm via runtime detection |
| `x86_64-windows-gnu` | LGPL and GPL |
| `x86_64-windows-msvc` | LGPL and GPL; cross builds need an [xwin] splat |
| `aarch64-windows-msvc` | Codec libraries only |
| `x86_64-macos`, `aarch64-macos` | LGPL and GPL, without Apple frameworks ([limitations](#known-limitations)) |

The glibc suffix sets the oldest glibc the output runs on. Every target that builds FFmpeg is
checked against a real `configure` run ([Verification](#verification)).

## Libraries

| Area | Libraries |
| --- | --- |
| Video | [dav1d], [libaom], [svt-av1], [libvpx], [openh264], [kvazaar], [vvenc], [libtheora], [x264]\*, [x265]\*, [xvidcore]\* |
| Image | [libwebp], [libjxl], [openjpeg], [zimg] |
| Audio | [opus], [lame], [libvorbis], [libogg], [speex], [twolame], [libgsm], [soxr], [rubberband]\* |
| Text and subtitles | [libass], [freetype], [harfbuzz], [fribidi] |
| Filters and analysis | [libvmaf], [vidstab]\* |
| Compression and support | [zlib], [bzip2], [xz], [brotli], [snappy], [highway], [libxml2] |
| Network | [OpenSSL] on Linux; schannel on Windows |
| Hardware | NVENC/NVDEC/CUDA ([nv-codec-headers]), VA-API ([libva], [libdrm]; Linux), oneVPL ([libvpl]), [AMF], OpenCL ([OpenCL headers][opencl-headers], [ICD loader][opencl-icd-loader]), [Vulkan headers][vulkan-headers]; D3D11VA, DXVA2, D3D12VA and Media Foundation on Windows |

\* GPL, built only with `-Dgpl`. LGPL builds never download GPL sources.

NVENC/NVDEC, oneVPL and OpenCL are built for Linux and Windows. OpenSSL is absent from GPL builds
unless `-Dversion3` is set.

FFmpeg 8.1 is the default; 9.0 is available with `-Dffmpeg-version=9.0`. All other versions are
pinned in `build.zig.zon`.

## Options

| Option | Effect |
| --- | --- |
| `-Dtarget=<triple>` | Target to build for |
| `-Dgpl` | Add the GPL libraries; drops OpenSSL unless combined with `-Dversion3` |
| `-Dversion3` | (L)GPLv3 licensing, which allows OpenSSL in GPL builds |
| `-Dffmpeg-version=8.1\|9.0` | FFmpeg release |
| `-D<library>=false` | Skip a library; FFmpeg's components resolve without it, as with configure |
| `-Donly=<library>\|ffmpeg` | Build a single library |
| `-Dffmpeg=false` | Build only the libraries, not FFmpeg |
| `-Dprograms` | Also build `ffmpeg` and `ffprobe` |
| `-Dstrip=false` | Keep debug info (stripped by default outside Debug) |
| `-Dwinsdk=<dir>` | xwin splat for msvc targets when building off Windows |

Library option names match `zig build --help` (`-Dlibvpx=false`, `-Dopus=false`, ...). Disabling
a library that another depends on skips the dependent, with a warning.

## Output

`zig-out/` contains `lib/` (static archives), `include/`, and `bin/` when built with
`-Dprograms`.

The `bundle` step packs a directory and a matching `.tar.zst` containing:

- every static archive
- FFmpeg's headers
- `MANIFEST.json`: the link order (FFmpeg's libraries, then dependencies in topological order,
  then the C++ runtime and system libraries), plus the version, URL and SHA-256 of every source
- license files for everything that ships

`bundle-check` links a C program against the bundle in exactly the manifest's order, with no
linker groups. It links with lld and, on a matching host, GNU ld, and runs the result on Linux.

## Verification

The build reimplements FFmpeg's configure inside the build graph. CI checks it three ways:

- **Configuration oracles.** For each target and variant, a real `configure` run against the same
  libraries is stored in `gen/ffmpeg/<version>/<target>-<variant>/oracle`. CI diffs every
  generated `config.h` key, component list and per-library source list against it, and fails on
  any difference outside a short list of intentional ones.
- **FATE.** FFmpeg's full [FATE] suite runs against the x86_64 Linux LGPL and GPL builds.
- **Bundle link check.** Every target's bundle goes through `bundle-check`, which catches a wrong
  link order or a symbol no archive defines.

## How it works

Each library is a port file in `build/`: a translation of its upstream build logic for the
target, plus registry metadata used by `build.zig`.

Anything upstream generates with perl, python or bash (libvpx and libaom RTCD headers, FFmpeg's
component lists) is checked in under `gen/`, with its generator in `tools/`. Building needs only
Zig; only maintainers need the upstream toolchains.

## Known limitations

- **macOS:** no VideoToolbox, AudioToolbox or TLS, because Zig ships no macOS SDK.
- **Vulkan:** shader-based filters are disabled, since the graph has no GLSL compiler.
- **Testing depth:** Windows and macOS outputs are cross-built and link-tested. Linux x86_64 is
  the most thoroughly tested target.

## License

The build code in this repository is MIT. Each upstream source keeps its own license. The
combined license of a build, as FFmpeg's configure reports it, is:

| Flags | License |
| --- | --- |
| *(default)* | LGPLv2.1+ |
| `-Dgpl` | GPLv2+ |
| `-Dversion3` | LGPLv3+ |
| `-Dgpl -Dversion3` | GPLv3+ |

Bundles include the license files of every shipped library.

[FFmpeg]: https://ffmpeg.org/
[FATE]: https://fate.ffmpeg.org/
[Zig]: https://ziglang.org/
[zig-download]: https://ziglang.org/download/
[xwin]: https://github.com/Jake-Shadle/xwin

[AMF]: https://github.com/GPUOpen-LibrariesAndSDKs/AMF
[brotli]: https://github.com/google/brotli
[bzip2]: https://sourceware.org/bzip2/
[dav1d]: https://code.videolan.org/videolan/dav1d
[freetype]: https://freetype.org/
[fribidi]: https://github.com/fribidi/fribidi
[harfbuzz]: https://harfbuzz.github.io/
[highway]: https://github.com/google/highway
[kvazaar]: https://github.com/ultravideo/kvazaar
[lame]: https://lame.sourceforge.io/
[libaom]: https://aomedia.googlesource.com/aom
[libass]: https://github.com/libass/libass
[libdrm]: https://gitlab.freedesktop.org/mesa/libdrm
[libgsm]: https://www.quut.com/gsm/
[libjxl]: https://github.com/libjxl/libjxl
[libogg]: https://xiph.org/ogg/
[libtheora]: https://www.theora.org/
[libva]: https://github.com/intel/libva
[libvmaf]: https://github.com/Netflix/vmaf
[libvorbis]: https://xiph.org/vorbis/
[libvpl]: https://github.com/intel/libvpl
[libvpx]: https://chromium.googlesource.com/webm/libvpx
[libwebp]: https://developers.google.com/speed/webp
[libxml2]: https://gitlab.gnome.org/GNOME/libxml2
[nv-codec-headers]: https://github.com/FFmpeg/nv-codec-headers
[opencl-headers]: https://github.com/KhronosGroup/OpenCL-Headers
[opencl-icd-loader]: https://github.com/KhronosGroup/OpenCL-ICD-Loader
[openh264]: https://www.openh264.org/
[openjpeg]: https://www.openjpeg.org/
[OpenSSL]: https://openssl-library.org/
[opus]: https://opus-codec.org/
[rubberband]: https://breakfastquay.com/rubberband/
[snappy]: https://github.com/google/snappy
[soxr]: https://sourceforge.net/projects/soxr/
[speex]: https://www.speex.org/
[svt-av1]: https://gitlab.com/AOMediaCodec/SVT-AV1
[twolame]: https://www.twolame.org/
[vidstab]: https://github.com/georgmartius/vid.stab
[vulkan-headers]: https://github.com/KhronosGroup/Vulkan-Headers
[vvenc]: https://github.com/fraunhoferhhi/vvenc
[x264]: https://www.videolan.org/developers/x264.html
[x265]: https://www.videolan.org/developers/x265.html
[xvidcore]: https://labs.xvid.com/
[xz]: https://tukaani.org/xz/
[zimg]: https://github.com/sekrit-twc/zimg
[zlib]: https://zlib.net/

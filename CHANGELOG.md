# Changelog

Releases are named after the FFmpeg version they build plus a revision: `8.1.3-r2` is the second
release of FFmpeg 8.1.3. A new revision ships only when the bundled archives change, through a
library update, a new library or a build fix. The hash in a bundle's name covers every archive in
it, so an unchanged hash means unchanged contents.

## [8.1.3-r1] - 2026-11-18

First release.

### Build

- Bundles for x86_64 and aarch64 Linux (glibc 2.17+), x86_64 Windows (MinGW and MSVC), and x86_64
  and aarch64 macOS, each in an LGPL and a GPL variant.
- Static `ffmpeg` and `ffprobe` for every bundle, in a separate `programs` archive; on Linux they
  need only glibc ([8198b6e](https://github.com/Xevion/ffmpeg-hermetic/commit/8198b6e)).
- A CycloneDX SBOM (`sbom.cdx.json`) in every archive, with the SPDX license of each source; the
  MANIFEST lists the same licenses ([bcbc2f6](https://github.com/Xevion/ffmpeg-hermetic/commit/bcbc2f6)).
- Every target's FFmpeg configuration matches a real `configure` run; FFmpeg's FATE suite passes on
  x86_64 Linux.
- Bundles are byte-identical across build directories (checked on Linux and Windows); Windows
  objects no longer carry nasm's assembly timestamp
  ([19af86c](https://github.com/Xevion/ffmpeg-hermetic/commit/19af86c)).

### Libraries

GPL bundles add rubberband, vidstab, x264, x265 and xvidcore. OpenSSL is in Linux LGPL bundles
only; VA-API (libva, libdrm) is Linux-only; oneVPL, OpenCL and nv-codec-headers are Linux and
Windows.

| Library | Version | License |
| --- | --- | --- |
| amf | 1.5.3 | MIT |
| brotli | 1.2.1 | MIT |
| bzip2 | 1.0.8 | bzip2-1.0.6 |
| dav1d | 1.5.4 | BSD-2-Clause |
| ffmpeg | 8.1.3 | lgpl: LGPL-2.1-or-later, gpl: GPL-2.0-or-later |
| freetype | 2.15.0 | FTL OR GPL-2.0-or-later |
| fribidi | 1.0.18 | LGPL-2.1-or-later |
| harfbuzz | 15.1.0 | MIT-Modern-Variant |
| highway | 1.4.0 | Apache-2.0 OR BSD-3-Clause |
| kvazaar | 2.3.2 | BSD-3-Clause |
| lame | 4.0 | LGPL-2.0-or-later |
| libaom | 3.15.3 | BSD-2-Clause |
| libass | 0.17.5 | ISC |
| libdrm | 2.4.134 | MIT |
| libgsm | 1.0.24 | TU-Berlin-2.0 |
| libjxl | 0.13.0 | BSD-3-Clause |
| libogg | 1.3.6 | BSD-3-Clause |
| libtheora | 1.2.0 | BSD-3-Clause |
| libva | 2.24.1 | MIT |
| libvmaf | 3.2.1 | BSD-2-Clause-Patent |
| libvorbis | 1.3.7 | BSD-3-Clause |
| libvpl | 2.17.0 | MIT |
| libvpx | 1.17.0 | BSD-3-Clause |
| libwebp | 1.6.0 | BSD-3-Clause |
| libxml2 | 2.15.4 | MIT |
| nv-codec-headers | n12.1.14.0 | MIT |
| opencl | 2026.05.29 | Apache-2.0 |
| opencl-headers | 2026.05.29 | Apache-2.0 |
| openh264 | 2.7.0 | BSD-2-Clause |
| openjpeg | 2.5.4 | BSD-2-Clause |
| openssl | 3.6.5 | Apache-2.0 |
| opus | 1.6.1 | BSD-3-Clause |
| rubberband | 4.0.0 | GPL-2.0-or-later |
| skcms | 96d9171c | BSD-3-Clause |
| snappy | 1.3.1 | BSD-3-Clause |
| soxr | 0.1.3 | LGPL-2.1-or-later |
| speex | 1.2.1 | BSD-3-Clause |
| svt-av1 | 3.1.2 | BSD-3-Clause-Clear AND BSD-2-Clause |
| twolame | 0.4.0 | LGPL-2.1-or-later |
| vidstab | 1.1.2 | GPL-2.0-or-later |
| vulkan-headers | 1.4.368 | Apache-2.0 OR MIT |
| vvenc | 1.14.0 | BSD-3-Clause-Clear |
| x264 | b35605ac | GPL-2.0-or-later |
| x265 | 4.2 | GPL-2.0-or-later |
| xvidcore | 013c664b | GPL-2.0-or-later |
| xz | 5.8.4 | 0BSD |
| zimg | 3.0.6 | WTFPL |
| zlib | 1.4 | Zlib |

[8.1.3-r1]: https://github.com/Xevion/ffmpeg-hermetic/releases/tag/8.1.3-r1

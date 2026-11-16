#!/usr/bin/env bash
# Runs FFmpeg's real configure, with zig cc as the compiler, against codec libraries this build
# produced. Maintainer-only: its output feeds tools/ffmpeg_extract.py and the config oracle.
# usage: tools/ffmpeg_configure.sh <ffmpeg-src> <codec-prefix> <build-dir> lgpl|gpl [target]
set -euo pipefail
src=$(realpath "${1:?ffmpeg source dir}")
prefix=$(realpath "${2:?prefix with lib/ and include/ from zig build}")
bld=${3:?build dir}
variant=${4:?lgpl or gpl}
target=${5:-x86_64-linux-gnu.2.17}
arch=${target%%-*}
repo=$(cd "$(dirname "$0")/.." && pwd)
nvh=${NV_CODEC_HEADERS:?set NV_CODEC_HEADERS to the nv-codec-headers source dir}

rm -rf "$bld"
mkdir -p "$bld/tools" "$bld/pkgconfig"
bld=$(realpath "$bld")

for sub in cc c++; do
  lang=c; [ "$sub" = c++ ] && lang=c++
  cat > "$bld/tools/$sub" <<WRAP
#!/bin/sh
hasx=0; stdin=0
for a in "\$@"; do case "\$a" in -x|-x?*) hasx=1;; -) stdin=1;; esac; done
set -- -target $target -fno-sanitize=undefined -g0 "\$@"
if [ \$stdin = 1 ] && [ \$hasx = 0 ]; then set -- -x $lang "\$@"; fi
exec zig $sub "\$@"
WRAP
  chmod +x "$bld/tools/$sub"
done
printf '#!/bin/sh\nexec zig ar "$@"\n' > "$bld/tools/ar"
printf '#!/bin/sh\nexec zig ranlib "$@"\n' > "$bld/tools/ranlib"
chmod +x "$bld/tools/ar" "$bld/tools/ranlib"

pc() { # name version libs [private libs]
  cat > "$bld/pkgconfig/$1.pc" <<PC
prefix=$prefix
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: $1
Version: $2
Description: $1
Libs: -L\${libdir} $3
Libs.private: ${4:-}
Cflags: -I\${includedir} ${5:-}
PC
}
pc zlib 1.3.2 -lz
pc dav1d 1.5.3 -ldav1d "-lpthread -lm"
pc opus 1.6.1 -lopus -lm "-I$prefix/include/opus"
sed -i "s|^Cflags: .*|Cflags: -I$prefix/include/opus|" "$bld/pkgconfig/opus.pc"
pc kvazaar 2.3.2 -lkvazaar "-lpthread -lm"
pc SvtAv1Enc 3.1.2 -lSvtAv1Enc "-lpthread -lm" "-I$prefix/include/svt-av1"
sed -i "s|^Cflags: .*|Cflags: -I$prefix/include/svt-av1|" "$bld/pkgconfig/SvtAv1Enc.pc"
pc aom 3.12.1 -laom "-lpthread -lm"
pc vpx 1.16.0 -lvpx "-lpthread -lm"
pc openh264 2.6.0 -lopenh264 "-lc++ -lm -lpthread"
pc x264 0.165 -lx264 "-lpthread -lm"
pc x265 4.1 -lx265 "-lc++ -lm -lpthread"
pc libdrm 2.4.133 -ldrm "" "-I$prefix/include/libdrm"
sed -i "s|^Cflags: .*|Cflags: -I$prefix/include -I$prefix/include/libdrm|" "$bld/pkgconfig/libdrm.pc"
pc libva 1.23.0 -lva
pc libva-drm 1.23.0 -lva
cat > "$bld/pkgconfig/ffnvcodec.pc" <<PC
Name: ffnvcodec
Version: 12.1.14.0
Description: ffnvcodec
Cflags: -I$nvh/include
PC

gpl=()
[ "$variant" = gpl ] && gpl=(--enable-gpl --enable-libx264 --enable-libx265)
cd "$bld"
PATH=$bld/tools:$PATH PKG_CONFIG_LIBDIR=$bld/pkgconfig PKG_CONFIG_PATH='' "$src/configure" \
  --prefix=/ffoxide-ffmpeg --cc="$bld/tools/cc" --cxx="$bld/tools/c++" --ar="$bld/tools/ar" \
  --ranlib="$bld/tools/ranlib" --arch="$arch" --target-os=linux --enable-cross-compile \
  --pkg-config=pkg-config --pkg-config-flags=--static \
  --extra-cflags="-I$prefix/include" --extra-ldflags="-L$prefix/lib" \
  --enable-static --disable-shared --enable-pic --disable-programs --disable-doc --disable-debug \
  --disable-autodetect --enable-runtime-cpudetect --enable-network --enable-pixelutils \
  --enable-zlib --enable-libdav1d --enable-libopus --enable-libopenh264 --enable-libaom --enable-libkvazaar \
  --enable-libsvtav1 --enable-libmp3lame --enable-libvpx \
  --enable-ffnvcodec --enable-nvenc --enable-nvdec --enable-cuvid --enable-cuda-llvm --enable-vaapi --enable-libdrm \
  --x86asmexe="${NASM:-nasm}" --nvcc="${CLANG:-clang}" \
  "${gpl[@]}" ${EXTRA_CONFIGURE:-}
echo "configured: $bld (repo $repo)"

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
for shader in glslc glslang glslangValidator; do # keep the host's shader compiler out of the vulkan probe
  printf '#!/bin/sh\nexit 1\n' > "$bld/tools/$shader"
  chmod +x "$bld/tools/$shader"
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

requires() { # name requires [requires private]
  printf 'Requires: %s\nRequires.private: %s\n' "${2:-}" "${3:-}" >> "$bld/pkgconfig/$1.pc"
}
cflags() { # name flags
  sed -i "s|^Cflags: .*|Cflags: $2|" "$bld/pkgconfig/$1.pc"
}
pc vorbis 1.3.7 -lvorbis "-lm -logg"
pc vorbisenc 1.3.7 -lvorbisenc
requires vorbisenc vorbis
pc libwebp 1.6.0 -lwebp "-lsharpyuv -lm -lpthread"
pc libwebpmux 1.6.0 -lwebpmux
requires libwebpmux libwebp
pc libopenjp2 2.5.4 -lopenjp2 -lm "-I$prefix/include/openjpeg-2.5"
cflags libopenjp2 "-I$prefix/include/openjpeg-2.5"
pc freetype2 2.15.0 -lfreetype
cflags freetype2 "-I$prefix/include/freetype2"
pc fribidi 1.0.18 -lfribidi
cflags fribidi "-I$prefix/include/fribidi"
pc harfbuzz 15.1.0 -lharfbuzz "-lc++ -lm -lpthread"
cflags harfbuzz "-I$prefix/include/harfbuzz"
requires harfbuzz "" freetype2
pc libass 0.17.5 -lass -lm
requires libass "" "fribidi harfbuzz freetype2"
pc libhwy 1.4.0 -lhwy -lc++
pc libbrotlicommon 1.2.1 -lbrotlicommon -lm
pc libbrotlidec 1.2.1 -lbrotlidec
requires libbrotlidec libbrotlicommon
pc libbrotlienc 1.2.1 -lbrotlienc
requires libbrotlienc libbrotlicommon
pc libjxl 0.13.0 -ljxl "-ljxl_cms -lc++ -lm -lpthread"
requires libjxl "" "libhwy libbrotlienc libbrotlidec"
pc libjxl_threads 0.13.0 -ljxl_threads "-lc++ -lm -lpthread"
pc speex 1.2.1 -lspeex -lm
pc zimg 3.0.6 -lzimg "-lc++ -lm"
pc libvvenc 1.14.0 -lvvenc "-lc++ -lm -lpthread"
pc libvmaf 3.2.1 -lvmaf "-lc++ -lm -lpthread"
cflags libvmaf "-I$prefix/include/libvmaf"
pc libxml-2.0 2.15.4 -lxml2 "-lm -lpthread -ldl"
cflags libxml-2.0 "-I$prefix/include/libxml2"
pc vidstab 1.1.2 -lvidstab -lm
pc rubberband 4.0.0 -lrubberband "-lc++ -lm -lpthread"
pc openssl 3.6.5 "-lssl -lcrypto" "-ldl -lpthread"
pc vulkan 1.4.368 ""
pc OpenCL 3.0 -lOpenCL "-ldl -lpthread"
pc vpl 2.17.0 -lvpl "-lc++ -ldl -lpthread"
cflags vpl "-I$prefix/include/vpl"

gpl=() tls=(--enable-openssl)
if [ "$variant" = gpl ]; then
  gpl=(--enable-gpl --enable-libx264 --enable-libx265 --enable-libxvid --enable-libvidstab --enable-librubberband)
  tls=()
fi
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
  --enable-libvorbis --enable-libwebp --enable-libopenjpeg --enable-libtheora --enable-libsoxr --enable-libzimg \
  --enable-bzlib --enable-lzma --enable-libfreetype --enable-libfribidi --enable-libharfbuzz --enable-libass \
  --enable-libjxl --enable-libspeex --enable-libtwolame --enable-libgsm --enable-libsnappy --enable-libxml2 \
  --enable-libvvenc --enable-libvmaf --enable-vulkan --enable-amf --enable-libvpl --enable-opencl \
  --enable-ffnvcodec --enable-nvenc --enable-nvdec --enable-cuvid --enable-cuda-llvm --enable-vaapi --enable-libdrm \
  --x86asmexe="${NASM:-nasm}" --nvcc="${CLANG:-clang}" \
  "${gpl[@]}" "${tls[@]}" ${EXTRA_CONFIGURE:-}
echo "configured: $bld (repo $repo)"

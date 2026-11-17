#!/usr/bin/env bash
# Runs FFmpeg's FATE suite against a `zig build -Dprograms=true` install.
#
# usage: tools/fate.sh <prefix> <ffmpeg-src> <samples> [target [make-args...]]
#
#   prefix      install prefix holding bin/ffmpeg, bin/ffprobe, lib/*.a and share/ffmpeg-zig/config
#   ffmpeg-src  the unpacked FFmpeg tree (zig-pkg/<hash> of the ffmpeg dependency)
#   samples     FATE sample suite (`rsync -vrltLW rsync://fate-suite.ffmpeg.org/fate-suite/ <dir>`)
#   target      zig target the build used (default x86_64-linux-gnu.2.17)
#   make-args   passed to make, e.g. `fate-h264` or `-j2 fate-list` (default: -k fate)
#
# Environment: JOBS (default 6), TREE (default <prefix>/fate-tree), TARGET_EXEC (a wrapper such
# as qemu-aarch64 when the build cannot run natively), XFAIL (file of tests expected to fail,
# one `fate-name` per line, `#` comments allowed).
#
# FFmpeg's own make drives the tests inside a tree built by tools/fate_tree.py. ffmpeg, ffprobe
# and the seven libraries come from the zig build and are protected from rebuilds with `-o`;
# make compiles only the test programs (unit tests, API tests, checkasm) with zig cc and links
# them against the zig-built archives. Needs make, nasm, python3 and zig on PATH.
set -euo pipefail

if [ $# -lt 3 ]; then
    sed -n '2,/^set -e/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
    exit 2
fi
prefix=$(realpath "$1")
src=$(realpath "$2")
samples=$(realpath "$3")
target=${4:-x86_64-linux-gnu.2.17}
shift $(($# < 4 ? $# : 4))
jobs=${JOBS:-6}
tree=${TREE:-$prefix/fate-tree}
here=$(dirname "$(realpath "$0")")
[ -z "${XFAIL:-}" ] || XFAIL=$(realpath "$XFAIL")

python3 -I "$here/fate_tree.py" "$src" "$prefix" "$tree" "$target"

make_args=("$@")
[ ${#make_args[@]} -gt 0 ] || make_args=(-k fate)

protected=(-o ffmpeg -o ffprobe)
for lib in avutil swresample swscale avcodec avformat avfilter avdevice; do
    protected+=(-o "lib$lib/lib$lib.a")
done

cd "$tree"
rm -rf tests/data/fate
rm -f tests/pixfmts.mak
status=0
make -j"$jobs" "${make_args[@]}" "${protected[@]}" \
    SAMPLES="$samples" FATE_SAMPLES="$samples" FATE_TARGET_EXEC="${TARGET_EXEC:-}" || status=$?

shopt -s nullglob
reps=(tests/data/fate/*.rep)
if [ ${#reps[@]} -eq 0 ]; then
    echo "fate.sh: no test reports in $tree/tests/data/fate (make exited $status)" >&2
    exit 1
fi
# Each report is `name:status:start:end:...`; status is the test's exit code.
awk -F: '$2 != 0 { print "fate-" $1 }' "${reps[@]}" | sort > failed.txt
total=${#reps[@]}
failed=$(wc -l < failed.txt)
echo "fate.sh: $((total - failed)) of $total tests passed, $failed failed (list: $tree/failed.txt)"

if [ -n "${XFAIL:-}" ]; then
    grep -v '^#' "$XFAIL" | awk 'NF { print $1 }' | sort > xfail.txt
    comm -23 failed.txt xfail.txt > unexpected.txt
    comm -13 failed.txt xfail.txt > fixed.txt
    echo "fate.sh: $(wc -l < unexpected.txt) unexpected failures, $(wc -l < fixed.txt) expected failures now pass"
    [ ! -s unexpected.txt ] || { cat unexpected.txt >&2; exit 1; }
    exit 0
fi
[ "$failed" -eq 0 ] || exit 1

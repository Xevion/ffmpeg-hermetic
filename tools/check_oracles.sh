#!/usr/bin/env bash
# Checks the resolved FFmpeg configuration against every checked-in oracle, without compiling.
#
# usage: tools/check_oracles.sh [filter]
#
#   filter  only oracles whose directory contains this substring (e.g. `8.1/x86_64-linux`)
#
# Oracles live at gen/ffmpeg/<version>/<target>-<variant>/oracle. msvc oracles need the MSVC CRT
# and Windows SDK: they run on Windows hosts, or elsewhere when WINSDK names an xwin splat.
set -euo pipefail

root=$(dirname "$(dirname "$(realpath "$0")")")
cd "$root"
python=$(command -v python3 || command -v python)
out=${OUT:-zig-out/oracles}
status=0
checked=0

for dir in gen/ffmpeg/*/*/oracle; do
    [[ $dir == *"${1:-}"* ]] || continue
    rel=${dir#gen/ffmpeg/}
    version=${rel%%/*}
    name=${rel#*/}
    name=${name%/oracle}
    variant=${name##*-}
    target=${name%-*}
    flags=(-Dffmpeg-version="$version")
    [[ $variant == gpl ]] && flags+=(-Dgpl)
    case $target in
        *-linux) target=$target-gnu.2.17 ;;
        *-windows-msvc)
            if [[ -n ${WINSDK:-} ]]; then
                flags+=(-Dwinsdk="$WINSDK")
            elif [[ $(uname -s) != MINGW* && $(uname -s) != MSYS* ]]; then
                echo "skip $rel (msvc needs WINSDK off Windows)"
                continue
            fi
            ;;
    esac
    prefix=$out/$version/$name
    echo "== $rel"
    if zig build -Dtarget="$target" --release=fast -Donly=ffmpeg "${flags[@]}" --prefix "$prefix" ffmpeg-config &&
        "$python" tools/check_config.py "$prefix/share/ffmpeg-hermetic/config" "$dir"; then
        checked=$((checked + 1))
    else
        status=1
    fi
done

echo "$checked oracle(s) matched"
exit $status

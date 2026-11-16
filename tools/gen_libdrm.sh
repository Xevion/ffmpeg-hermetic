#!/usr/bin/env bash
# Regenerates gen/libdrm/ from an unpacked libdrm source tree (needs python3).
# usage: tools/gen_libdrm.sh <libdrm-src>
set -euo pipefail
src=${1:?usage: gen_libdrm.sh <libdrm-src>}
out=$(cd "$(dirname "$0")/.." && pwd)/gen/libdrm
mkdir -p "$out"
python3 -I "$src/gen_table_fourcc.py" "$src/include/drm/drm_fourcc.h" "$out/generated_static_table_fourcc.h"

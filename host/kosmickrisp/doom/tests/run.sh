#!/bin/sh
# Pass the test ICD manifest. All builds and shader products are temporary.
set -eu
if [ "$#" -ne 1 ]; then echo "Usage: $0 /path/to/icd.json" >&2; exit 2; fi
export VK_DRIVER_FILES="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
export KK_EMULATION=performance,+depth_bounds,+line_expansion,+float64
here=$(cd "$(dirname "$0")" && pwd)
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
for stage in vert frag; do
    glslangValidator -V "$here/features.$stage" -o "$build/features.$stage.spv"
done
cc -O2 "$here/features.c" $(pkg-config --cflags --libs vulkan) -o "$build/check"
for mode in dynamic static; do
    if [ "$mode" = static ]; then export STATIC_WIDTH=1; else unset STATIC_WIDTH; fi
    NO_BOUNDS=1 "$build/check" "$build"
    "$build/check" "$build"
done

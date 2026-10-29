#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Builds premierenux_json.dll with the MinGW-w64 cross compiler (Arch Linux: pacman -S mingw-w64-gcc; Debian and Ubuntu:
# gcc-mingw-w64-x86-64; the headers must be recent enough to have windows.data.json.h).
#   build.sh [OUTPUT.dll]     (default: ./premierenux_json.dll)
# The SHA-256 that it prints belongs into SHIM_SHA of ../install.sh when the shipped DLL is replaced.
set -eu
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT=${1:-$HERE/premierenux_json.dll}
CC=${CC:-x86_64-w64-mingw32-gcc}
command -v "$CC" > /dev/null 2>&1 || { echo "error: $CC not found (the MinGW-w64 cross compiler)" >&2; exit 1; }
"$CC" -O2 -Wall -Wextra -Wno-unused-parameter -shared -o "$OUT" \
    "$HERE/premierenux_json.c" "$HERE/premierenux_json.def" \
    -lruntimeobject -lole32 -luuid -static-libgcc
x86_64-w64-mingw32-strip --strip-unneeded "$OUT" 2> /dev/null || true
echo "built $OUT ($(stat -c %s "$OUT") bytes, sha256 $(sha256sum "$OUT" | cut -c1-64))"

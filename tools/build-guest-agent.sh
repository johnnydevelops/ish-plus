#!/bin/bash
# Builds ishplus-agent (tools/guest/agent) for the guest: a static aarch64
# Linux binary, with Homebrew's LLVM and a sysroot of Alpine's musl and
# kernel headers. Output: build-guest/agent/ishplus-agent
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build-guest/agent"
ALPINE="https://dl-cdn.alpinelinux.org/alpine/v3.24/main/aarch64"
CLANG="$(brew --prefix llvm)/bin/clang"
SYSROOT="$WORK/sysroot"
mkdir -p "$WORK/apks" "$SYSROOT"
if [ ! -e "$SYSROOT/usr/lib/libc.a" ]; then
    curl -fsSL "$ALPINE/APKINDEX.tar.gz" | tar -xzO APKINDEX > "$WORK/APKINDEX"
    for p in musl musl-dev linux-headers compiler-rt; do
        v=$(awk -v p="$p" 'BEGIN { RS = "" } index($0, "P:" p "\n") { match($0, /\nV:[^\n]*/); print substr($0, RSTART + 3, RLENGTH - 3); exit }' "$WORK/APKINDEX")
        [ -n "$v" ] || { echo "no Alpine package $p" >&2; exit 1; }
        [ -f "$WORK/apks/$p.apk" ] || curl -fsSL -o "$WORK/apks/$p.apk" "$ALPINE/$p-$v.apk"
        tar -xzf "$WORK/apks/$p.apk" -C "$SYSROOT" 2>/dev/null || true
    done
fi
BUILTINS=$(find "$SYSROOT" -name "libclang_rt.builtins*aarch64*.a" | head -1)
"$CLANG" --target=aarch64-linux-musl --sysroot="$SYSROOT" -fuse-ld=lld -static -O2 -Wall \
    -nostdlib "$SYSROOT/usr/lib/crt1.o" "$SYSROOT/usr/lib/crti.o" \
    "$ROOT/tools/guest/agent/agent.c" -o "$WORK/ishplus-agent" \
    -L"$SYSROOT/usr/lib" -lc ${BUILTINS:+"$BUILTINS"} "$SYSROOT/usr/lib/crtn.o"
"$(brew --prefix llvm)/bin/llvm-strip" "$WORK/ishplus-agent"
ls -la "$WORK/ishplus-agent"

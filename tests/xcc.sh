#!/bin/sh
# Cross-compile a test program for i386 Linux (musl) on the host, using the
# headers and libraries of an iSH root filesystem made with fakefsify.
# Usage: tests/xcc.sh <fakefs dir> <output> <source.c> [cc flags...]
# gcc running inside iSH is not used, so tests do not depend on the emulator
# compiling them correctly.
set -e
fs="$1"; out="$2"; shift 2
sysroot="$(cd "$fs/data" && pwd)"
gccdir="$(ls -d "$sysroot"/usr/lib/gcc/*/* | head -1)"
exec clang -target i386-linux-musl --sysroot="$sysroot" --gcc-install-dir="$gccdir" \
    -fuse-ld=lld -static -no-pie -O1 -w -o "$out" "$@"

#!/bin/bash
# Builds QEMU's system emulators (aarch64 and x86_64) for iOS from our fork
# (deps/qemu, branch ishplus, based on UTM's QEMU fork, which carries the iOS
# JIT handling, the shared library build and the TCTI threaded interpreter),
# plus the libraries a headless VM needs: glib, libffi, pixman, libslirp
# (user-mode networking) and libucontext (coroutines; iOS has no makecontext).
# The libraries are upstream releases.
#
# Usage: tools/build-qemu-ios.sh [stage...]
#   stages: fetch deps qemu qemu-tci (default: all)
#
# Requires Homebrew meson, ninja, pkg-config, glib (for glib-mkenums).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${QEMU_BUILD_DIR:-$ROOT/build-qemu}"
SRC="$WORK/src"
PREFIX="$WORK/sysroot-ios-arm64"
QEMU_DIR="$ROOT/deps/qemu"
NCPU="$(sysctl -n hw.ncpu)"

# Pinned upstream sources
FFI_SRC="https://github.com/libffi/libffi/releases/download/v3.5.0/libffi-3.5.0.tar.gz"
GLIB_SRC="https://download.gnome.org/sources/glib/2.90/glib-2.90.1.tar.xz"
PIXMAN_SRC="https://www.cairographics.org/releases/pixman-0.46.4.tar.gz"
SLIRP_SRC="https://gitlab.freedesktop.org/slirp/libslirp/-/archive/v4.9.7/libslirp-v4.9.7.tar.gz"
LIBUCONTEXT_SRC="https://github.com/kaniini/libucontext/archive/refs/tags/libucontext-1.5.2.tar.gz"

# ---------------------------------------------------------------- toolchain
MINVER="15.0"
SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
TARGET="-target arm64-apple-ios$MINVER"
export CC="$(xcrun --sdk iphoneos --find clang) $TARGET"
export CXX="$(xcrun --sdk iphoneos --find clang++) $TARGET"
export OBJCC="$CC"
export AR="$(xcrun --sdk iphoneos --find ar)"
export NM="$(xcrun --sdk iphoneos --find nm)"
export RANLIB="$(xcrun --sdk iphoneos --find ranlib)"
export STRIP="$(xcrun --sdk iphoneos --find strip)"
COMMON="-arch arm64 -isysroot $SDKROOT -I$PREFIX/include"
export CFLAGS="$COMMON -O2"
export CXXFLAGS="$CFLAGS"
export OBJCFLAGS="$CFLAGS"
export LDFLAGS="-arch arm64 -isysroot $SDKROOT -L$PREFIX/lib $TARGET"
# Only look at what we built, never at Homebrew's macOS libraries.
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH=""
# pipe2/dup3 exist in the iOS 27 SDK headers but not on older iOS versions;
# configure checks that declare their own prototypes would miss that.
export ac_cv_func_pipe2=no ac_cv_func_dup3=no
HOST=aarch64-apple-darwin

log() { printf '\033[0;32m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- fetching
fetch() { # url [dir name] -> extracted into $SRC/<name>, patched from tools/qemu-ios-patches
    local url="$1" file name
    file="$(basename "$url")"
    name="${2:-${file%.tar.*}}"
    [ -d "$SRC/$name" ] && return
    mkdir -p "$SRC/dl" "$SRC/$name"
    [ -f "$SRC/dl/$file" ] || curl -fL --retry 3 -o "$SRC/dl/$file" "$url"
    tar -xf "$SRC/dl/$file" -C "$SRC/$name" --strip-components 1
    local patch="$ROOT/tools/qemu-ios-patches/$name.patch"
    if [ -f "$patch" ]; then
        log "Patching $name"
        (cd "$SRC/$name" && patch -p1 < "$patch")
    fi
}

stage_fetch() {
    fetch "$FFI_SRC"
    fetch "$GLIB_SRC"
    fetch "$PIXMAN_SRC"
    fetch "$SLIRP_SRC"
    fetch "$LIBUCONTEXT_SRC" libucontext-1.5.2
}

# ---------------------------------------------------------------- builders
meson_cross_file() { # system -> path
    local cross="$WORK/meson-$1.cross"
    q() { local out="" w; for w in $*; do out="$out'$w',"; done; echo "[${out%,}]"; }
    cat > "$cross" <<EOF
[properties]
needs_exe_wrapper = true
has_function_pipe2 = false
has_function_dup3 = false
[built-in options]
c_args = $(q $CFLAGS)
cpp_args = $(q $CXXFLAGS)
objc_args = $(q $OBJCFLAGS)
c_link_args = $(q $LDFLAGS)
cpp_link_args = $(q $LDFLAGS)
objc_link_args = $(q $LDFLAGS)
[binaries]
c = $(q $CC)
cpp = $(q $CXX)
objc = $(q $OBJCC)
ar = '$AR'
nm = '$NM'
ranlib = '$RANLIB'
strip = ['$STRIP', '-x']
pkg-config = '$(command -v pkg-config)'
python = '$(command -v python3)'
glib-mkenums = '$(command -v glib-mkenums)'
glib-compile-resources = '$(command -v glib-compile-resources)'
[host_machine]
system = '$1'
$( [ "$1" = darwin ] && printf "kernel = 'xnu'\nsubsystem = 'ios'\n" )
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOF
    echo "$cross"
}

autotools() { # dir configure-args...
    local dir="$1"; shift
    log "Building $(basename "$dir")"
    (cd "$dir" && ./configure --prefix="$PREFIX" --host="$HOST" "$@" && make -j"$NCPU" && make install)
}

mesonb() { # dir system meson-args...
    local dir="$1" system="$2"; shift 2
    log "Building $(basename "$dir")"
    local cross; cross="$(meson_cross_file "$system")"
    (cd "$dir" && rm -rf ishplus_build &&
        meson setup ishplus_build --prefix="$PREFIX" --buildtype=release --cross-file "$cross" "$@" &&
        meson compile -C ishplus_build -j "$NCPU" && meson install -C ishplus_build)
}

stage_deps() {
    mkdir -p "$PREFIX"
    autotools "$SRC/libffi-3.5.0" --disable-shared --enable-static --disable-docs
    mesonb "$SRC/glib-2.90.1" darwin -Ddefault_library=static -Dtests=false -Ddtrace=disabled \
        -Dnls=disabled -Dintrospection=disabled -Dlibmount=disabled -Dselinux=disabled \
        -Dlibelf=disabled -Dsysprof=disabled -Ddocumentation=false -Dman-pages=disabled
    mesonb "$SRC/pixman-0.46.4" darwin -Ddefault_library=static -Dtests=disabled -Ddemos=disabled \
        -Dgtk=disabled -Dlibpng=disabled -Da64-neon=enabled -Dopenmp=disabled
    mesonb "$SRC/libslirp-v4.9.7" darwin -Ddefault_library=static
    mesonb "$SRC/libucontext-1.5.2" darwin -Ddefault_library=static -Dfreestanding=true
}

configure_qemu() { # build-dir prefix target-list extra-args...
    local build="$1" prefix="$2" targets="$3"; shift 3
    mkdir -p "$build"
    (cd "$build" && "$QEMU_DIR/configure" --prefix="$prefix" --cross-prefix="" \
        --target-list="$targets" "$@" \
        --enable-shared-lib --enable-ucontext --with-coroutine=libucontext \
        --enable-tcg --enable-slirp --disable-slirp-smbd \
        --disable-hvf --disable-cocoa --disable-sdl --disable-gtk --disable-coreaudio \
        --disable-vmnet --disable-vnc --disable-spice --disable-opengl --disable-curses \
        --disable-tools --disable-guest-agent --disable-docs --disable-debug-info \
        --disable-gnutls --disable-nettle --disable-gcrypt --disable-curl --disable-libssh \
        --disable-libusb --disable-usb-redir --disable-smartcard --disable-capstone \
        --disable-zstd --disable-bzip2 --disable-lzo --disable-snappy --disable-png \
        --disable-plugins --disable-keyring --disable-rust &&
        make -j"$NCPU" && make install)
}

# JIT build: libqemu-{aarch64,x86_64}-softmmu.dylib
stage_qemu() {
    log "Building QEMU (deps/qemu)"
    configure_qemu "$WORK/qemu-build" "$PREFIX" aarch64-softmmu,x86_64-softmmu
}

# Build for when JIT cannot be enabled, with the TCTI threaded interpreter
# (much faster than QEMU's TCI): libqemu-aarch64-softmmu-tci.dylib
stage_qemu-tci() {
    log "Building QEMU with the threaded interpreter (TCTI)"
    configure_qemu "$WORK/qemu-build-tci" "$WORK/tci-install" aarch64-softmmu \
        --enable-tcg-threaded-interpreter --extra-cflags=-Wno-unused-command-line-argument \
        --extra-ldflags=-Wl,-no_deduplicate --extra-ldflags=-Wl,-no_compact_unwind
    cp "$WORK/tci-install/lib/libqemu-aarch64-softmmu.dylib" "$PREFIX/lib/libqemu-aarch64-softmmu-tci.dylib"
    install_name_tool -id @rpath/libqemu-aarch64-softmmu-tci.dylib "$PREFIX/lib/libqemu-aarch64-softmmu-tci.dylib"
}

stages=("$@")
[ ${#stages[@]} -eq 0 ] && stages=(fetch deps qemu qemu-tci)
for s in "${stages[@]}"; do "stage_$s"; done
log "Done: $PREFIX"

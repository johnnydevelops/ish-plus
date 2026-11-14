#!/bin/sh
# Builds iSH+'s on-device pairing library (ffi/rppairing, Rust, using
# idevice) for iOS: build-rppairing/libishplus_rppairing.a, linked into the
# app. Needs Rust with the aarch64-apple-ios target
# (rustup target add aarch64-apple-ios).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.cargo/bin:$PATH"
cd "$ROOT/ffi/rppairing"
mkdir -p "$ROOT/build-rppairing"
# The simulator: stand-ins (no device to pair with), so iSH+ builds for it
if [ "${PLATFORM_NAME:-iphoneos}" = iphonesimulator ]; then
    xcrun --sdk iphonesimulator clang -c -target arm64-apple-ios17.4-simulator simulator.c \
        -o "$ROOT/build-rppairing/simulator.o"
    rm -f "$ROOT/build-rppairing/libishplus_rppairing.a"
    ar rcs "$ROOT/build-rppairing/libishplus_rppairing.a" "$ROOT/build-rppairing/simulator.o"
    exit 0
fi
IPHONEOS_DEPLOYMENT_TARGET=17.4 cargo build --release --target aarch64-apple-ios
mkdir -p "$ROOT/build-rppairing"
cp target/aarch64-apple-ios/release/libishplus_rppairing.a "$ROOT/build-rppairing/"

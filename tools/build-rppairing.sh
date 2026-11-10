#!/bin/sh
# Builds iSH+'s on-device pairing library (ffi/rppairing, Rust, using
# idevice) for iOS: build-rppairing/libishplus_rppairing.a, linked into the
# app. Needs Rust with the aarch64-apple-ios target
# (rustup target add aarch64-apple-ios).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.cargo/bin:$PATH"
cd "$ROOT/ffi/rppairing"
IPHONEOS_DEPLOYMENT_TARGET=17.4 cargo build --release --target aarch64-apple-ios
mkdir -p "$ROOT/build-rppairing"
cp target/aarch64-apple-ios/release/libishplus_rppairing.a "$ROOT/build-rppairing/"

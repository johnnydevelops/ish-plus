#!/bin/sh
# Builds iSH+ for iOS devices and packages an ad-hoc ("fake") signed .ipa.
# Sideloaders (AltStore, SideStore, Feather, etc.) re-sign it with a real
# certificate, keeping the entitlements: get-task-allow (so a debugger can
# attach, which JIT needs), the app group, and the increased memory limit
# and extended virtual addressing the VM uses.
#
# Usage: tools/package-ipa.sh [output.ipa]
# Needs the QEMU libraries (tools/build-qemu-ios.sh), the guest
# (tools/make-guest-kernel.sh, tools/make-guest-support.sh), StikJIT
# (tools/fetch-stikjit.sh) and Rust for on-device pairing
# (rustup target add aarch64-apple-ios).
set -eu

SRCROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${ISH_BUILD_DIR:-$SRCROOT/build}"
OUT="${1:-$WORK/iSH+.ipa}"
DERIVED="$WORK/DerivedData"
CONFIG="${CONFIGURATION:-Release}"

mkdir -p "$WORK"
xcodebuild -project "$SRCROOT/iSH.xcodeproj" -scheme iSH -configuration "$CONFIG" \
    -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" \
    ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build

PRODUCTS="$DERIVED/Build/Products/$CONFIG-iphoneos"
APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PRODUCTS/iSH.app/Info.plist")"
GROUP="group.$APP_ID"

STAGE="$WORK/ipa-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/Payload"
cp -R "$PRODUCTS/iSH.app" "$STAGE/Payload/"
APP="$STAGE/Payload/iSH.app"

ent() {
    # $1 = output path, $2 = extra keys
    cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.application-groups</key>
	<array><string>$GROUP</string></array>
	<key>get-task-allow</key>
	<true/>
$2
</dict>
</plist>
EOF
}
ent "$WORK/app.entitlements" "	<key>com.apple.developer.kernel.increased-memory-limit</key>
	<true/>
	<key>com.apple.developer.kernel.extended-virtual-addressing</key>
	<true/>"
ent "$WORK/appex.entitlements" ""

sign() {
    # $1 = bundle or binary, $2 = entitlements (optional)
    if [ -n "${2:-}" ]; then
        codesign --force --sign - --timestamp=none --entitlements "$2" --generate-entitlement-der "$1"
    else
        codesign --force --sign - --timestamp=none "$1"
    fi
}

# Sign inside-out: libraries and extensions first, then the app
for item in "$APP"/Frameworks/*; do
    sign "$item"
done
for appex in "$APP"/PlugIns/*.appex; do
    [ -e "$appex" ] || continue
    sign "$appex" "$WORK/appex.entitlements"
done
sign "$APP" "$WORK/app.entitlements"

rm -f "$OUT"
mkdir -p "$(dirname "$OUT")"
(cd "$STAGE" && zip -qry "$OUT" Payload)
echo "Wrote $OUT ($(du -h "$OUT" | cut -f1))"

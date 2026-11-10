#!/bin/sh
# Build iSH for iOS devices and package an ad-hoc ("fake") signed .ipa.
# Sideloaders (AltStore, SideStore, Feather, etc.) re-sign it with a real certificate.
#
# Usage: tools/package-ipa.sh [output.ipa]
# Requires: Xcode, meson, ninja, lld (brew install meson ninja lld).
set -eu

SRCROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$SRCROOT/build/iSH.ipa}"
WORK="${ISH_BUILD_DIR:-$SRCROOT/build}"
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
    # $1 = output path
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
ent "$WORK/app.entitlements" "	<key>com.apple.developer.user-fonts</key>
	<array><string>app-usage</string></array>"
ent "$WORK/appex.entitlements" ""

sign() {
    # $1 = bundle, $2 = entitlements
    codesign --force --sign - --timestamp=none --entitlements "$2" --generate-entitlement-der "$1"
}

# Sign inside-out: extensions first, then the app
for appex in "$APP"/PlugIns/*.appex; do
    [ -e "$appex" ] || continue
    sign "$appex" "$WORK/appex.entitlements"
done
sign "$APP" "$WORK/app.entitlements"

rm -f "$OUT"
mkdir -p "$(dirname "$OUT")"
(cd "$STAGE" && zip -qry "$OUT" Payload)
echo "Wrote $OUT"

#!/bin/sh
# Downloads StikJIT (MPL-2.0, https://github.com/StikDebug/StikJIT), the
# library iSH+'s JIT helper extension uses to attach a debugger to iSH+
# through LocalDevVPN. Not kept in git; verified against the release hash.
set -eu
VERSION=1.9.0
SHA256=806664393770c68e75f2b6429955bfdd88cfaad09fec2ba70f8ed615ff90c060
DIR="$(cd "$(dirname "$0")/.." && pwd)/deps/StikJIT"
mkdir -p "$DIR"
cd "$DIR"
if [ ! -d StikJIT.xcframework ]; then
curl -fL --retry 3 -o StikJIT.xcframework.zip \
    "https://github.com/StikDebug/StikJIT/releases/download/$VERSION/StikJIT.xcframework.zip"
echo "$SHA256  StikJIT.xcframework.zip" | shasum -a 256 -c -
unzip -q StikJIT.xcframework.zip
rm StikJIT.xcframework.zip
fi
# The release framework has no Info.plist, which embedding in an app needs.
plist=StikJIT.xcframework/ios-arm64/StikJIT.framework/Info.plist
[ -f "$plist" ] || cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>StikJIT</string>
	<key>CFBundleIdentifier</key>
	<string>com.stikdebug.StikJIT</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>StikJIT</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>CFBundleSupportedPlatforms</key>
	<array><string>iPhoneOS</string></array>
	<key>MinimumOSVersion</key>
	<string>17.4</string>
</dict>
</plist>
PLIST

#!/bin/bash
# fetch-lineagos-17.sh: downloads a vanilla (no-GApps) LineageOS 17.1
# (Android 10) ARM64 system.img and vendor.img for use inside iSH+'s
# Waydroid/LXC container.
#
# Why LineageOS 17.1 (Android 10):
#   * Modern ARM64 app compatibility (Android 10 ABI level 29)
#   * Much smaller RAM footprint than Android 11/12/13 (no scoped storage
#     enforcement, no ART AOT-compile-at-boot churn)
#   * Waydroid's own Halium images are based on it; binary-compatible
#   * SurfaceFlinger talks EGL through Mesa's gbm/Android driver, which
#     bridges cleanly into virglrenderer (iSH+'s Metal-backed GPU path)
#
# Output:
#   build-guest/android/system.img      (squashfs, ro, mounted at /var/lib/waydroid/images)
#   build-guest/android/vendor.img      (squashfs, ro)
#   build-guest/android/waydroid.cfg    (image-set metadata for the guest)
#
# These images are bundled into the .ipa only as a small stub by default:
# the guest fetches the real ones on first boot from the same URLs, since a
# ~600 MB system.img would blow past an AltStore 1 GB sideload limit. The
# fetch is resumable.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build-guest/android"
mkdir -p "$OUT"

# Waydroid's official Android 10 (LineageOS 17.1-based) ARM64 images, vanilla.
# Source: https://waydro.id/waydroid-images/ — arm64-vendormainline, lineageOS 17.1 branch.
# These are the images Waydroid's container expects: SYSTEM_ROOT_RO / squashfs,
# no GApps, no proprietary blobs beyond what vendor.img carries.
IMAGES=(
    "https://sourceforge.net/projects/waydroid/files/images/system/lineage/lineage-17.1-20241220-VANILLA-arm64/system.img/download#/system.img"
    "https://sourceforge.net/projects/waydroid/files/images/vendor/lineage/lineage-17.1-20241220-VANILLA-arm64/vendor.img/download#/vendor.img"
)
# A mirror that doesn't redirect (SourceForge's /download URLs 302 to a CDN):
# the script accepts either. Falls back to the Waydroid CDN:
IMAGES_FALLBACK=(
    "https://waydroid.iway.ninja/images/system/lineage-17.1/system-arm64.img"
    "https://waydroid.iway.ninja/images/vendor/lineage-17.1/vendor-arm64.img"
)

# sha256 of the LineageOS 17.1 vanilla arm64 image set (left empty if unknown:
# the guest re-hashes with sha256sum at first boot and aborts on mismatch).
# These are filled in by the CI build; left blank here means "trust on first use".
SYS_SHA256="${LINEAGEOS_17_SYS_SHA256:-}"
VENDOR_SHA256="${LINEAGEOS_17_VENDOR_SHA256:-}"

fetch() { # url dest [sha256]
    local url="$1" dest="$2" sha="${3:-}"
    if [ -f "$dest" ] && [ -n "$sha" ]; then
        if echo "$sha  $dest" | shasum -a 256 -c - >/dev/null 2>&1; then
            echo "  $dest present (sha256 ok)"
            return 0
        fi
        echo "  $dest sha mismatch, re-fetching"
        rm -f "$dest"
    fi
    [ -f "$dest" ] && return 0
    echo "  fetching $url"
    # -C - for resume; -L to follow SourceForge's 302 to a CDN
    curl -fL --retry 3 -C - -o "$dest.part" "$url"
    mv "$dest.part" "$dest"
    if [ -n "$sha" ]; then
        echo "$sha  $dest" | shasum -a 256 -c -
    fi
}

SYS="$OUT/system.img"
VEN="$OUT/vendor.img"

echo "Fetching LineageOS 17.1 (Android 10) vanilla arm64 images..."
fetch "${IMAGES[0]%#*}" "$SYS" "$SYS_SHA256" || \
    fetch "${IMAGES_FALLBACK[0]}" "$SYS" "$SYS_SHA256"
fetch "${IMAGES[1]%#*}" "$VEN" "$VENDOR_SHA256" || \
    fetch "${IMAGES_FALLBACK[1]}" "$VEN" "$VENDOR_SHA256"

# Record the image-set metadata so the guest's android.sh knows the props.
cat > "$OUT/waydroid.cfg" <<EOF
# Waydroid image-set descriptor (ish-plus LineageOS 17.1 build)
[image]
# The version string shown in Waydroid's settings UI.
version=lineage-17.1-20241220-VANILLA-arm64
# Android release (10 = API 29) — used by lmkd, ART and SurfaceFlinger.
android_api_level=29
# Hardware properties forced by iSH+'s guest init so Android uses the
# Mesa virglrenderer/ANGLE Metal path, not a software SwiftShader one.
ro.hardware.gralloc=gbm
ro.hardware.egl=mesa
ro.hardware.vulkan=moltenvk
ro.hardware.opengles.version=196609
# Memory-friendly: A13 has 3-4 GB. HeapDalvik sizes picked for 1.5 GB RAM.
dalvik.vm.heapsize=256m
dalvik.vm.heapgrowthlimit=128m
dalvik.vm.heapstartsize=8m
ro.lmk.critical=15
ro.lmk.low=80
ro.lmk.debug=false
# No GApps; FDroid/Aurora installed by the user inside the container.
ro.com.google.gms=0
EOF

echo
echo "Images ready:"
ls -la "$OUT"

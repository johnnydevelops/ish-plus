#!/bin/bash
# Builds iSH+'s default kernel side: Debian's prebuilt arm64 kernel with 16 KB
# pages (linux-image-arm64-16k, nothing compiled here), run with QEMU's pages
# at 16 KB too (-M virt,ishplus-pagebits=14). make-guest-kernel.sh builds the
# 4 KB one (Settings > Linux VM > 4K Pages). Same layout, so
# tools/guest/boot/init is unchanged:
#   vmlinuz      Debian's kernel (gzip Image, which QEMU's -kernel unpacks)
#   initramfs    Alpine's netboot initramfs (busybox), plus Debian's modules
#                for the boot disks and iSH+'s /init
#   modloop      Debian's modules (squashfs), trimmed to what a VM can use
#
# Output: build-guest/kernel16k/
# Requires OrbStack/Docker (the module tree is built in Linux: APFS is
# case-insensitive) and the Alpine netboot bundle from make-guest-kernel.sh.
set -euo pipefail
ALPINE="3.24.4"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build-guest"
OUT="$WORK/kernel16k"
NETBOOT="$WORK/dl/alpine-netboot-$ALPINE-aarch64.tar.gz"
[ -f "$NETBOOT" ] || { echo "run tools/make-guest-kernel.sh first" >&2; exit 1; }
mkdir -p "$OUT"
stage="$(mktemp -d "$WORK/stage16k.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
tar -xf "$NETBOOT" -C "$stage" boot/initramfs-virt
install -m 755 "$ROOT/tools/guest/boot/init" "$stage/init"

docker run --rm --platform linux/arm64 -v "$stage:/w" debian:trixie bash -euo pipefail -c '
apt-get update -qq
apt-get install -y -qq --no-install-recommends kmod squashfs-tools cpio xz-utils zstd gzip >/dev/null
cd /tmp
apt-get download -qq $(apt-cache depends linux-image-arm64-16k | sed -n "s/.*Depends: \(linux-image-[0-9].*-arm64-16k\)$/\1/p" | head -1)
dpkg-deb -x linux-image-*.deb pkg
kver=$(ls pkg/usr/lib/modules)
echo "kernel $kver"
# QEMU loads a plain Image (or Image.gz); Debian ships an EFI zboot image
# or a gzip Image, depending on the release
img=pkg/boot/vmlinuz-$kver
if gzip -t "$img" 2>/dev/null; then cp "$img" /w/vmlinuz; else gzip -9c "$img" > /w/vmlinuz; fi
m=pkg/usr/lib/modules/$kver
# Trim: no hardware a VM never has (keeps virtio, filesystems, networking,
# crypto, input, DRM virtio-gpu, sound, USB for passthrough-like devices).
# The Android / Waydroid / LXC subsystems (binderfs, ashmem, zram, uinput,
# sync_file, fuse, overlayfs, veth, bridge, macvlan, dummy, tun) are kept so
# LineageOS 17.1 boots inside an LXC container. See deps/android-waydroid.config.
find $m/kernel/drivers -mindepth 1 -maxdepth 1 -type d \
    ! -name virtio ! -name block ! -name net ! -name char ! -name gpu \
    ! -name input ! -name hid ! -name md ! -name scsi ! -name nvme ! -name usb \
    ! -name vhost ! -name video ! -name i2c ! -name base ! -name dma-buf \
    ! -name crypto ! -name firmware ! -name rtc ! -name pci ! -name iommu \
    ! -name vdpa ! -name fuse ! -name hwmon ! -name tty ! -name virt \
    ! -name android ! -name staging \
    -exec rm -rf {} +
rm -rf $m/kernel/sound/soc $m/kernel/drivers/net/wireless $m/kernel/drivers/net/ethernet \
       $m/kernel/drivers/gpu/drm/{amd,radeon,nouveau,i915,xe,msm,panfrost,lima,etnaviv,rockchip,tegra,sun4i,meson,mediatek,imx,hisilicon,bridge,panel}
# Force-keep the modules Waydroid/LineageOS needs even if they would be
# pruned by the rules above (some live under staging/ or are .ko files
# inside the surviving driver directories). Listed explicitly so a future
# Debian kernel release that reorganises them still keeps them.
keep_android_modules() {
    for rel in \
        kernel/drivers/android/binderfs.ko \
        kernel/drivers/android/binder_linux.ko \
        kernel/drivers/staging/android/ashmem.ko \
        kernel/drivers/md/zram.ko \
        kernel/drivers/input/misc/uinput.ko \
        kernel/drivers/dma-buf/sync_file.ko \
        kernel/drivers/net/macvlan.ko \
        kernel/drivers/net/dummy.ko \
        kernel/drivers/net/tun.ko \
        kernel/fs/fuse/fuse.ko \
        kernel/fs/overlayfs/overlay.ko \
        kernel/net/bridge/bridge.ko \
        kernel/net/bridge/br_netfilter.ko \
        kernel/net/ipv4/netfilter/ipt_MASQUERADE.ko \
        kernel/net/netfilter/xt_MASQUERADE.ko \
    ; do
        [ -e "$m/$rel" ] && echo "$m/$rel"
    done
}
# Re-add any that the broad find above removed (staging/ and android/)
mkdir -p /tmp/android-keep
keep_android_modules | while read -r f; do
    dest=/tmp/android-keep/${f#$m/}
    mkdir -p "$(dirname "$dest")"; cp "$f" "$dest"
done 2>/dev/null || true
# Uncompressed modules: busybox modprobe in the initramfs reads plain .ko
find $m -name "*.ko.xz" -exec xz -d {} +
find $m -name "*.ko.zst" -exec zstd -q -d --rm {} +
# Re-add the Android/Waydroid modules we saved (in case they were pruned)
[ -d /tmp/android-keep ] && cp -an /tmp/android-keep/. "$m/" 2>/dev/null || true
depmod -b pkg/usr "$kver"
mkdir -p /tmp/sq/modules && cp -a $m /tmp/sq/modules/
mksquashfs /tmp/sq /w/modloop -comp xz -all-root -noappend -quiet
# The boot modules (and what they depend on) into the initramfs
mkdir -p /tmp/extra/usr/lib/modules/$kver
for mod in virtio_pci virtio_blk squashfs ext4 \
           binderfs binder_linux ashmem zram uinput sync_file \
           fuse overlay bridge veth macvlan dummy tun; do
    modprobe -d pkg/usr -S "$kver" --show-depends $mod 2>/dev/null | sed -n "s|^insmod ||p" | cut -d" " -f1
done | sort -u | while read -r f; do
    [ -e "$f" ] || continue
    rel=${f#*/modules/$kver/}
    mkdir -p "/tmp/extra/usr/lib/modules/$kver/$(dirname "$rel")"
    cp "$f" "/tmp/extra/usr/lib/modules/$kver/$rel"
done
cp $m/modules.* /tmp/extra/usr/lib/modules/$kver/
cp /w/init /tmp/extra/init
(cd /tmp/extra && find . | cpio -o -H newc --quiet | gzip -9) > /w/extra.cpio.gz
echo "$kver" > /w/kver
'
cp "$stage/vmlinuz" "$stage/modloop" "$OUT/"
cat "$stage/boot/initramfs-virt" "$stage/extra.cpio.gz" > "$OUT/initramfs"
echo "Debian $(cat "$stage/kver")"
ls -la "$OUT"

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
# crypto, input, DRM virtio-gpu, sound, USB for passthrough-like devices)
find $m/kernel/drivers -mindepth 1 -maxdepth 1 -type d \
    ! -name virtio ! -name block ! -name net ! -name char ! -name gpu \
    ! -name input ! -name hid ! -name md ! -name scsi ! -name nvme ! -name usb \
    ! -name vhost ! -name video ! -name i2c ! -name base ! -name dma-buf \
    ! -name crypto ! -name firmware ! -name rtc ! -name pci ! -name iommu \
    ! -name vdpa ! -name fuse ! -name hwmon ! -name tty ! -name virt \
    -exec rm -rf {} +
rm -rf $m/kernel/sound/soc $m/kernel/drivers/net/wireless $m/kernel/drivers/net/ethernet \
       $m/kernel/drivers/gpu/drm/{amd,radeon,nouveau,i915,xe,msm,panfrost,lima,etnaviv,rockchip,tegra,sun4i,meson,mediatek,imx,hisilicon,bridge,panel}
# Uncompressed modules: busybox modprobe in the initramfs reads plain .ko
find $m -name "*.ko.xz" -exec xz -d {} +
find $m -name "*.ko.zst" -exec zstd -q -d --rm {} +
depmod -b pkg/usr "$kver"
mkdir -p /tmp/sq/modules && cp -a $m /tmp/sq/modules/
mksquashfs /tmp/sq /w/modloop -comp xz -all-root -noappend -quiet
# The boot modules (and what they depend on) into the initramfs
mkdir -p /tmp/extra/usr/lib/modules/$kver
for mod in virtio_pci virtio_blk squashfs ext4; do
    modprobe -d pkg/usr -S "$kver" --show-depends $mod | sed -n "s|^insmod ||p" | cut -d" " -f1
done | sort -u | while read -r f; do
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

#!/bin/bash
# Builds the arm64 kernel side of iSH+'s Linux VM, shared by every
# distribution (iSH+ bundles it; distributions are downloaded in the app):
#   vmlinuz      Alpine's linux-virt kernel
#   initramfs    Alpine's netboot initramfs, plus the ext4 driver and iSH+'s
#                own /init (tools/guest/boot/init), which installs and boots
#                distributions
#   modloop      the kernel's modules (squashfs), attached as a disk and
#                mounted on /lib/modules, as Alpine itself does. Extracting the
#                modules on macOS would lose some, since their names differ
#                only in case and APFS is case-insensitive.
#
# Output: build-guest/kernel/
# Requires Homebrew squashfs.
set -euo pipefail

VERSION="3.24.4"
ARCH="aarch64"
MIRROR="https://dl-cdn.alpinelinux.org/alpine/v${VERSION%.*}/releases/$ARCH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build-guest"
OUT="$WORK/kernel"

mkdir -p "$WORK/dl" "$OUT"
for f in "alpine-netboot-$VERSION-$ARCH.tar.gz"; do
    [ -f "$WORK/dl/$f" ] || curl -fL --retry 3 -o "$WORK/dl/$f" "$MIRROR/$f"
done

stage="$WORK/stage-$VERSION-$ARCH"
rm -rf "$stage"
mkdir -p "$stage/netboot"

# Kernel, initramfs and modules all come from the netboot bundle, so they match.
tar -xf "$WORK/dl/alpine-netboot-$VERSION-$ARCH.tar.gz" -C "$stage/netboot"
cp "$stage/netboot/boot/vmlinuz-virt" "$OUT/vmlinuz"
cp "$stage/netboot/boot/modloop-virt" "$OUT/modloop"

# Append ext4 and its dependencies to the initramfs (concatenated cpio
# archives are unpacked in order by the kernel).
kver="$(gzip -dc "$stage/netboot/boot/initramfs-virt" | cpio -t 2>/dev/null | sed -n 's|^usr/lib/modules/\([^/]*\)/.*|\1|p' | head -1)"
mods="kernel/fs/ext4/ext4.ko kernel/lib/crc/crc16.ko kernel/fs/mbcache.ko kernel/fs/jbd2/jbd2.ko"
# All of the module indexes (kmod reads modules.dep.bin, not modules.dep)
unsquashfs -q -d "$stage/modloop" "$OUT/modloop" \
    $(for i in dep dep.bin alias alias.bin symbols symbols.bin softdep devname order builtin builtin.bin builtin.alias.bin builtin.modinfo; do echo "modules/$kver/modules.$i"; done) \
    $(for m in $mods; do echo "modules/$kver/$m"; done) >/dev/null
mkdir -p "$stage/extra/usr/lib/modules"
cp -R "$stage/modloop/modules/$kver" "$stage/extra/usr/lib/modules/"
# iSH+'s init replaces Alpine's (later archives overwrite earlier files)
install -m 755 "$ROOT/tools/guest/boot/init" "$stage/extra/init"
(cd "$stage/extra" && find . | cpio -o -H newc --quiet | gzip -9) > "$stage/extra.cpio.gz"
cat "$stage/netboot/boot/initramfs-virt" "$stage/extra.cpio.gz" > "$OUT/initramfs"

rm -rf "$stage"
ls -la "$OUT"

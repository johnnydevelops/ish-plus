#!/bin/bash
# Builds a bootable arm64 Alpine Linux guest for the QEMU engine:
#   vmlinuz      Alpine linux-virt kernel
#   initramfs    Alpine's netboot initramfs plus an appended archive with the
#                ext4 driver, which netboot does not need
#   modloop      the kernel's modules (squashfs), attached as a second disk and
#                mounted on /lib/modules, as Alpine itself does. Extracting the
#                modules on macOS would lose some, since their names differ
#                only in case and APFS is case-insensitive.
#   rootfs.img   ext4 disk with the minirootfs and an inittab that starts a
#                login on every virtio console
#
# Usage: tools/make-guest-alpine.sh [size, default 2G]
# Output: build-guest/alpine-<version>-aarch64/
# Requires Homebrew e2fsprogs and squashfs.
set -euo pipefail

VERSION="3.24.4"
ARCH="aarch64"
SIZE="${1:-2G}"
MIRROR="https://dl-cdn.alpinelinux.org/alpine/v${VERSION%.*}/releases/$ARCH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build-guest"
OUT="$WORK/alpine-$VERSION-$ARCH"
E2FS="$(brew --prefix e2fsprogs)/sbin"

mkdir -p "$WORK/dl" "$OUT"
for f in "alpine-minirootfs-$VERSION-$ARCH.tar.gz" "alpine-netboot-$VERSION-$ARCH.tar.gz"; do
    [ -f "$WORK/dl/$f" ] || curl -fL --retry 3 -o "$WORK/dl/$f" "$MIRROR/$f"
done

stage="$WORK/stage-$VERSION-$ARCH"
rm -rf "$stage"
mkdir -p "$stage/netboot" "$stage/rootfs"

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
(cd "$stage/extra" && find . | cpio -o -H newc --quiet | gzip -9) > "$stage/extra.cpio.gz"
cat "$stage/netboot/boot/initramfs-virt" "$stage/extra.cpio.gz" > "$OUT/initramfs"

tar -xpf "$WORK/dl/alpine-minirootfs-$VERSION-$ARCH.tar.gz" -C "$stage/rootfs"
mkdir -p "$stage/rootfs/.modloop" "$stage/rootfs/lib/modules"

# Guest configuration: logins on the virtio consoles (one per iSH+ session),
# networking through QEMU's user-mode network, and the Files app share.
cat > "$stage/rootfs/etc/inittab" <<'EOF'
::sysinit:/usr/sbin/ishplus-init
::respawn:/usr/sbin/ishplus-console hvc0
::respawn:/usr/sbin/ishplus-console hvc1
::respawn:/usr/sbin/ishplus-console hvc2
::respawn:/usr/sbin/ishplus-console hvc3
::ctrlaltdel:/sbin/reboot
::shutdown:/bin/umount -a -r
EOF
# Boot setup. The initramfs has already mounted /proc, /sys and /dev, so only
# mount what is missing (mounting them again fails with "Resource busy").
cat > "$stage/rootfs/usr/sbin/ishplus-init" <<'INIT'
#!/bin/sh
mnt() { mountpoint -q "$3" || mount -t "$1" "$2" "$3"; }
mnt proc proc /proc
mnt sysfs sysfs /sys
mnt devtmpfs devtmpfs /dev
mkdir -p /dev/pts /dev/shm /run
mnt devpts devpts /dev/pts
mnt tmpfs tmpfs /dev/shm
mnt tmpfs tmpfs /run
mount -o remount,rw /
# Kernel modules live on the second disk (Alpine's modloop)
mountpoint -q /.modloop || mount -t squashfs -o ro /dev/vdb /.modloop
mountpoint -q /lib/modules || mount --bind /.modloop/modules /lib/modules
hostname -F /etc/hostname
# Log to /var/log/messages; without a syslog daemon, programs like login
# print their log messages on the console instead.
syslogd -s 512 -b 1
ifconfig lo up
ifconfig eth0 up
udhcpc -b -q -n -t 5 -i eth0 -s /usr/share/udhcpc/default.script >/dev/null 2>&1
# Developer hook: run a script the app attached as a disk (serial
# "ishplus-autorun"), with its output on the serial port (serial.log).
for serial in /sys/block/vd*/serial; do
    [ "$(cat "$serial" 2>/dev/null)" = ishplus-autorun ] || continue
    dev=/dev/$(basename "$(dirname "$serial")")
    (sleep 2; sh "$dev" > /dev/ttyAMA0 2>&1) &
done
INIT
chmod 755 "$stage/rootfs/usr/sbin/ishplus-init"
# A root shell on one iSH+ session's console, logged in automatically like
# iSH; consoles the app did not attach wait quietly instead of making init
# respawn a failing getty forever.
cat > "$stage/rootfs/usr/sbin/ishplus-console" <<'CONSOLE'
#!/bin/sh
[ -e "/dev/$1" ] || exec sleep 2147483647
exec /sbin/getty -n -l /usr/sbin/ishplus-autologin 0 "$1" xterm-256color
CONSOLE
cat > "$stage/rootfs/usr/sbin/ishplus-autologin" <<'AUTOLOGIN'
#!/bin/sh
exec /bin/login -f root
AUTOLOGIN
chmod 755 "$stage/rootfs/usr/sbin/ishplus-console" "$stage/rootfs/usr/sbin/ishplus-autologin"
echo "ishplus" > "$stage/rootfs/etc/hostname"
printf 'nameserver 10.0.2.3\n' > "$stage/rootfs/etc/resolv.conf"
# Log in as root without a password, like iSH
sed -i '' 's|^root:[^:]*:|root::|' "$stage/rootfs/etc/shadow"

rm -f "$OUT/rootfs.img"
"$E2FS/mke2fs" -q -t ext4 -L ishplus-root -d "$stage/rootfs" "$OUT/rootfs.img" "$SIZE"
# Ownership and modes as in the tarball (mke2fs -d used the Mac's owners);
# everything we added is root's.
{
    echo 'sif / uid 0'; echo 'sif / gid 0'
    (cd "$stage/rootfs" && find . -mindepth 1) | sed 's|^\.||' | while read -r p; do
        printf 'sif "%s" uid 0\nsif "%s" gid 0\n' "$p" "$p"
    done
    python3 "$ROOT/tools/guest/tar-owners.py" "$WORK/dl/alpine-minirootfs-$VERSION-$ARCH.tar.gz"
} | "$E2FS/debugfs" -w -f - "$OUT/rootfs.img" >/dev/null 2>&1

rm -rf "$stage"
ls -la "$OUT"

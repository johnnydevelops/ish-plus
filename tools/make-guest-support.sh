#!/bin/bash
# Builds iSH+'s guest support disk (support.img, squashfs), mounted in the
# guest at /opt/ishplus by ishplus-init, which then runs its init.sh. It holds
# what iSH+ adds to the guest and can be updated without touching the user's
# root filesystem:
#
#   fex/        FEX-Emu (MIT, https://fex-emu.com), from the FEX Ubuntu PPA, made
#               self-contained with Ubuntu's glibc and libstdc++ (the guest is
#               musl-based Alpine), so x86_64 programs run in the arm64 guest.
#   x86_64.tar.gz  Ubuntu 24.04's x86_64 base system (glibc, apt), the
#               libraries x86_64 programs see (FEX's RootFS), unpacked to
#               /opt/x86_64 on first boot; musl.tar adds musl's loader, so
#               musl programs (e.g. Alpine's) run too.
#   commands/   x86 (run an x86_64 command) and apt-x86 (install x86_64 packages)
#   boot/       iSH+'s init inside the distribution (see tools/guest/boot)
#   bin/, sbin/, lib/musl/  static busybox, tini and apk; mke2fs for the initramfs
#
# Output: build-guest/support.img
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build-guest/support"
OUT="$ROOT/build-guest/support.img"
ALPINE_VERSION=3.24.4

FEX_VERSION="2611-1~n"
FEX_PPA=https://ppa.launchpadcontent.net/fex-emu/fex/ubuntu
FEX_DEB="pool/main/f/fex-emu-armv8.4/fex-emu-armv8.4_${FEX_VERSION}_arm64.deb"
FEX_SHA256=37da9f385a8908e0d0f2691e718d41fe40fae8fd842d772151bc97402414b0a4
UBUNTU=http://ports.ubuntu.com/ubuntu-ports
UBUNTU_DEBS=(
    "pool/main/g/glibc/libc6_2.39-0ubuntu8.9_arm64.deb"
    "pool/main/g/gcc-14/libstdc++6_14.2.0-4ubuntu2~24.04.1_arm64.deb"
    "pool/main/g/gcc-14/libgcc-s1_14.2.0-4ubuntu2~24.04.1_arm64.deb"
)

command -v patchelf >/dev/null || { echo "needs patchelf (brew install patchelf)"; exit 1; }
command -v mksquashfs >/dev/null || { echo "needs mksquashfs (brew install squashfs)"; exit 1; }

mkdir -p "$WORK/downloads"
fetch() { # url [sha256]
    local file="$WORK/downloads/$(basename "$1")"
    [ -f "$file" ] || curl -fL --retry 3 -o "$file" "$1"
    if [ -n "${2:-}" ]; then echo "$2  $file" | shasum -a 256 -c - >/dev/null; fi
    echo "$file"
}
unpack_deb() { # deb dir
    mkdir -p "$2"
    (cd "$2" && ar x "$1" && tar -xf data.tar.* && rm -f data.tar.* control.tar.* debian-binary)
}

stage="$WORK/stage"
rm -rf "$stage" "$WORK/debs"
mkdir -p "$stage/fex/bin" "$stage/fex/lib" "$stage/fex/share" "$stage/bin" "$stage/sbin" \
         "$stage/lib/musl" "$stage/commands" "$stage/boot" "$WORK/debs" "$WORK/apks"

# Static tools that work in any distribution: busybox (iSH+'s init, network),
# tini (process 1), apk (x86_64 packages). mke2fs (dynamic, musl) is only
# used by the initramfs, which has musl, to format a distribution's disk.
ALPINE_REPOS="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION%.*}"
for repo in main community; do
    curl -fsSL "$ALPINE_REPOS/$repo/aarch64/APKINDEX.tar.gz" | tar -xzO APKINDEX > "$WORK/apks/APKINDEX-$repo"
done
apk_fetch() { # package -> unpacked directory
    local version="" repo dir="$WORK/apks/$1"
    for repo in main community; do
        version=$(awk -v p="$1" 'BEGIN { RS = "" } index($0, "P:" p "\n") { match($0, /\nV:[^\n]*/); print substr($0, RSTART + 3, RLENGTH - 3); exit }' "$WORK/apks/APKINDEX-$repo")
        [ -n "$version" ] && break
    done
    [ -n "$version" ] || { echo "no Alpine package $1" >&2; exit 1; }
    mkdir -p "$dir"
    tar -xzf "$(fetch "$ALPINE_REPOS/$repo/aarch64/$1-$version.apk")" -C "$dir" 2>/dev/null || true
    echo "$dir"
}
cp "$(apk_fetch busybox-static)/bin/busybox.static" "$stage/bin/busybox"
# iSH+'s own guest agent (port forwarding), see tools/guest/agent
"$ROOT/tools/build-guest-agent.sh" >/dev/null
cp "$ROOT/build-guest/agent/ishplus-agent" "$stage/bin/"
cp "$(apk_fetch tini-static)/sbin/tini-static" "$stage/bin/tini"
ln -s busybox "$stage/bin/modprobe"
cp "$(apk_fetch apk-tools-static)/sbin/apk.static" "$stage/bin/apk"
cp "$(apk_fetch e2fsprogs)/sbin/mke2fs" "$stage/sbin/mke2fs"
for p in e2fsprogs-libs libcom_err libblkid libuuid libeconf; do
    find "$(apk_fetch $p)" -name "*.so.*" -exec cp -L {} "$stage/lib/musl/" \;
done
cp "$ROOT/tools/guest/boot/main.sh" "$ROOT/tools/guest/boot/shell.sh" "$ROOT/tools/guest/boot/udhcpc.script" \
   "$ROOT/tools/guest/boot/port.sh" "$ROOT/tools/guest/boot/exec-agent.sh" "$stage/boot/"
# The iOS clipboard (like macOS's commands), through iSH+
cat > "$stage/commands/pbcopy" <<'EOF'
#!/bin/sh
# Copies standard input to the iOS clipboard.
B=/opt/ishplus/bin/busybox
. /opt/ishplus/boot/port.sh
P=$(port org.ishplus.clipboard) || { echo "pbcopy: the clipboard is not available" >&2; exit 1; }
t=$($B mktemp); trap '$B rm -f "$t"' EXIT
$B cat > "$t"
(
    $B flock 9
    { printf 'C %s\n' "$($B wc -c < "$t")"; $B cat "$t"; } > "$P"
) 9>/run/ishplus-clipboard.lock
EOF
cat > "$stage/commands/pbpaste" <<'EOF'
#!/bin/sh
# Prints the iOS clipboard's text.
B=/opt/ishplus/bin/busybox
. /opt/ishplus/boot/port.sh
P=$(port org.ishplus.clipboard) || { echo "pbpaste: the clipboard is not available" >&2; exit 1; }
(
    $B flock 9
    exec 3<>"$P"
    printf 'P\n' >&3
    read -r length <&3
    [ "$length" -gt 0 ] 2>/dev/null && $B head -c "$length" <&3
) 9>/run/ishplus-clipboard.lock
EOF

# FEX
unpack_deb "$(fetch "$FEX_PPA/$FEX_DEB" "$FEX_SHA256")" "$WORK/debs/fex"
for b in FEX FEXServer FEXGetConfig; do
    cp "$WORK/debs/fex/usr/bin/$b" "$stage/fex/bin/"
done
mkdir -p "$stage/fex/share/fex-emu"
cp -R "$WORK/debs/fex/usr/share/fex-emu/AppConfig" "$stage/fex/share/fex-emu/"
cat > "$stage/fex/share/fex-emu/Config.json" <<'EOF'
{
  "Config": {
    "RootFS": "/opt/x86_64"
  }
}
EOF

# glibc and the C++ runtime, used only by FEX
for deb in "${UBUNTU_DEBS[@]}"; do
    unpack_deb "$(fetch "$UBUNTU/$deb")" "$WORK/debs/$(basename "$deb" .deb)"
done
lib() { find "$WORK/debs" -path "*/aarch64-linux-gnu/$1" | head -1; }
for f in ld-linux-aarch64.so.1 libc.so.6 libm.so.6 libstdc++.so.6 libgcc_s.so.1; do
    cp -L "$(lib "$f")" "$stage/fex/lib/$f"
done
for b in "$stage"/fex/bin/*; do
    patchelf --set-interpreter /opt/ishplus/fex/lib/ld-linux-aarch64.so.1 \
             --force-rpath --set-rpath /opt/ishplus/fex/lib "$b"
done

# The x86_64 root: Ubuntu's base system, and musl's loader from its package
cp "$(fetch "https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.5-base-amd64.tar.gz" \
    e77b6f10c2590cef872b33ee9f635a0e3fd1f57fb074c0e52b5c7f56147a0c86)" "$stage/x86_64.tar.gz"
rm -rf "$WORK/musl" && mkdir -p "$WORK/musl"
(cd "$WORK/musl" && ar x "$(fetch http://archive.ubuntu.com/ubuntu/pool/universe/m/musl/musl_1.2.4-2_amd64.deb \
    9f0883c20b4b746e05e947bafd99cb933f5494ffaaa6fcd360cbe1fbcf264883)" && mkdir root && tar -xf data.tar.* -C root)
tar -cf "$stage/musl.tar" -C "$WORK/musl/root" --uid 0 --gid 0 .

cat > "$stage/commands/x86" <<'EOF'
#!/bin/sh
# Runs an x86_64 command from /opt/x86_64 (installed with apk-x86) through
# FEX, e.g. "x86 uname -m". Programs given by path run directly.
[ $# -gt 0 ] || { echo "usage: x86 command [args...]" >&2; exit 2; }
case "$1" in
*/*) exec "$@" ;;
esac
for dir in /usr/local/bin /usr/bin /bin /usr/local/sbin /usr/sbin /sbin; do
    if [ -x "/opt/x86_64$dir/$1" ]; then
        cmd="/opt/x86_64$dir/$1"; shift
        exec "$cmd" "$@"
    fi
done
echo "x86: $1: not found in /opt/x86_64 (install it with apt-x86 install)" >&2
exit 127
EOF
cat > "$stage/commands/apt-x86" <<'EOF'
#!/bin/sh
# apt for the x86_64 root used by x86_64 programs (/opt/x86_64, Ubuntu 24.04),
# e.g. "apt-x86 install libsdl2-2.0-0". Runs through FEX, so it is slow.
R=/opt/x86_64
X=/opt/ishplus/bin/busybox
if [ "$(id -u)" != 0 ]; then
    if command -v sudo >/dev/null; then
        exec sudo "$0" "$@"
    fi
    echo "apt-x86 needs root: enter the root password." >&2
    exec su root -c "$0 $*"
fi
for d in proc sys dev dev/pts; do
    $X mountpoint -q $R/$d || $X mount --bind /$d $R/$d
done
cp /etc/resolv.conf $R/etc/resolv.conf 2>/dev/null
exec $X chroot $R /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root TERM="$TERM" \
    DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get "$@"
EOF
chmod 755 "$stage/bin/"* "$stage/sbin/"* "$stage/commands/"* "$stage/boot/"*

# Run by boot/main.sh in the distribution, with this disk at /opt/ishplus.
# Uses the static busybox only, since distributions differ in their tools.
cat > "$stage/init.sh" <<'EOF'
#!/opt/ishplus/bin/busybox sh
S=/opt/ishplus
X=/opt/ishplus/bin/busybox
# iOS can end iSH+ at any moment; write changes to disk within ~2 seconds
# instead of Linux's default 30, so little is lost when that happens.
echo 200 > /proc/sys/vm/dirty_expire_centisecs
echo 100 > /proc/sys/vm/dirty_writeback_centisecs
# x86_64 programs run through FEX. Unpacked to a temporary directory and
# synced first, so an interrupted first boot does not leave empty files.
# (Earlier versions used Alpine's x86_64 root, without glibc: replaced.)
if [ ! -e /opt/x86_64/.ishplus-ubuntu ]; then
    $X rm -rf /opt/x86_64 /opt/.x86_64.new
    $X mkdir -p /opt/.x86_64.new
    $X tar -xzf $S/x86_64.tar.gz -C /opt/.x86_64.new && $X tar -xf $S/musl.tar -C /opt/.x86_64.new \
        && echo 'APT::Sandbox::User "root";' > /opt/.x86_64.new/etc/apt/apt.conf.d/99ishplus \
        && $X touch /opt/.x86_64.new/.ishplus-ubuntu && $X sync && $X mv /opt/.x86_64.new /opt/x86_64 && $X sync
fi
# apk-x86 from earlier versions
$X rm -f /usr/local/bin/apk-x86
$X cp /etc/resolv.conf /opt/x86_64/etc/resolv.conf 2>/dev/null
$X mkdir -p /usr/share /usr/local/bin
$X ln -sfn $S/fex/share/fex-emu /usr/share/fex-emu
# FEX also works in chroots of the x86_64 root (apk scripts)
$X mkdir -p /opt/x86_64$S
$X mountpoint -q /opt/x86_64$S || $X mount --bind $S /opt/x86_64$S
$X modprobe -q binfmt_misc
B=/proc/sys/fs/binfmt_misc
$X mountpoint -q $B || $X mount -t binfmt_misc binfmt_misc $B
if [ ! -e $B/FEX-x86_64 ]; then
    echo ':FEX-x86_64:M:0:\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\x00\x00\x00\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/opt/ishplus/fex/bin/FEX:POCF' > $B/register
fi
for cmd in $S/commands/*; do $X ln -sf "$cmd" /usr/local/bin/; done
EOF
chmod 755 "$stage/init.sh"

rm -f "$OUT"
mksquashfs "$stage" "$OUT" -comp zstd -all-root -noappend -quiet
ls -la "$OUT"

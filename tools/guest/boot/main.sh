# iSH+'s part inside the distribution: mounts, network, FEX, then a root
# shell on every iSH+ session's console. By default it runs as a service of
# the distribution's own init system (ISHPLUS_NATIVE=1, boot/native.sh),
# leaving it what an init system does; with the kernel argument
# ishplus.init=own (or an init system iSH+ does not know) it is process 1
# itself, under tini, with the support disk's static busybox (lighter).
B=/opt/ishplus/bin/busybox
S=/opt/ishplus
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
mnt() { $B mountpoint -q "$3" || { $B mkdir -p "$3"; $B mount -t "$1" "$2" "$3"; }; }
mnt devpts devpts /dev/pts
mnt tmpfs tmpfs /dev/shm
mnt tmpfs tmpfs /run
[ -n "$ISHPLUS_NATIVE" ] || mnt tmpfs tmpfs /tmp
$B mount -o remount,rw /
# Kernel modules from the modules disk, whatever the distribution ships
$B mkdir -p /lib/modules
$B mountpoint -q /lib/modules || $B mount --bind /.modloop/modules /lib/modules
# The kernel loads drivers on demand through a modprobe program, which not
# every distribution has: use busybox's
echo $S/bin/modprobe > /proc/sys/kernel/modprobe
# Drivers for the devices present (network, consoles, ...), as udev would
for alias in /sys/bus/*/devices/*/modalias; do
    a=$($B cat "$alias")
    # Not the display and its input (virtio-gpu, virtio-input): the Desktop
    # session loads them (boot/desktop.sh)
    case "$a" in virtio:d00000010v*|virtio:d00000012v*) continue ;; esac
    $B modprobe -q "$a" 2>/dev/null
done
$B hostname ishplus
# A machine ID, which systemd would make on first boot (D-Bus and desktops
# need one; distribution images ship it empty, or "uninitialized"). Other
# init systems make none.
if [ "$($B cat /proc/1/comm)" != systemd ] && ! $B grep -qE '^[0-9a-f]{32}$' /etc/machine-id 2>/dev/null; then
    $B tr -dc 0-9a-f < /dev/urandom | $B head -c 32 > /etc/machine-id
    echo >> /etc/machine-id
fi
[ -d /var/lib/dbus ] && [ ! -s /var/lib/dbus/machine-id ] && $B ln -sf /etc/machine-id /var/lib/dbus/machine-id
# Any user may ping (ICMP sockets need no privileges then): distributions'
# ping relies on file capabilities, which unpacking their archive loses
echo "0 2147483647" > /proc/sys/net/ipv4/ping_group_range
$B ifconfig lo up
$B ifconfig eth0 up 2>/dev/null
# With the distribution's init, its own network setup (systemd-networkd,
# NetworkManager...) may configure eth0: DHCP here only if it did not
has_addr() { $B ip -4 addr show eth0 2>/dev/null | $B grep -q "inet "; }
if [ -n "$ISHPLUS_NATIVE" ]; then
    i=0; while ! has_addr && [ $i -lt 10 ]; do $B sleep 0.5; i=$((i + 1)); done
fi
has_addr || $B udhcpc -b -q -n -t 5 -i eth0 -s $S/boot/udhcpc.script >/dev/null 2>&1
[ -x $S/init.sh ] && $S/init.sh
# Compressed swap in RAM (boot/swap.sh), unless the distribution has swap
$B sh $S/boot/swap.sh
# The Files app share: iSH+'s Documents/Shared folder, at /mnt/ios, and as
# iOS in the user's home
$B modprobe -q 9pnet_virtio; $B modprobe -q 9p
$B mkdir -p /mnt/ios
$B mount -t 9p -o trans=virtio,version=9p2000.L,msize=1048576,cache=mmap ishplus-share /mnt/ios 2>/dev/null
user=$($B cat /etc/ishplus/user 2>/dev/null)
home=/root
[ -n "$user" ] && home=$($B awk -F: -v u="$user" '$1 == u { print $6 }' /etc/passwd)
# Sound: the user may use the sound card (the audio group), from any
# session, not only the desktop's (whose seat grants it with systemd)
if [ -n "$user" ] && $B grep -q '^audio:' /etc/group && \
   ! $B grep -qE "^audio:[^:]*:[^:]*:(.*,)?$user(,|\$)" /etc/group; then
    $B addgroup "$user" audio 2>/dev/null
fi
# Files added to the share from iOS belong to the user
. $S/boot/port.sh
if P=$(port org.ishplus.clipboard); then
    owner=${user:-root}
    printf 'U %s %s\n' "$($B id -u "$owner")" "$($B id -g "$owner")" > "$P"
fi
if [ -d "$home" ] && [ ! -e "$home/iOS" ]; then
    $B ln -s /mnt/ios "$home/iOS"
    [ -n "$user" ] && $B chown -h "$user:" "$home/iOS"
fi
# Developer channel, only when Shared/.ishplus-dev exists: runs cmd.sh as
# root whenever its first line changes after boot, output in out.txt (lets commands
# run without restarting iSH+, e.g. while switching VPNs)
if [ -d /mnt/ios/.ishplus-dev ]; then
    (
        # Only commands sent from now on (not the last one, at every boot)
        D=/mnt/ios/.ishplus-dev; last=$($B head -1 $D/cmd.sh 2>/dev/null)
        while :; do
            id=$($B head -1 $D/cmd.sh 2>/dev/null)
            if [ -n "$id" ] && [ "$id" != "$last" ]; then
                last=$id
                $B sh $D/cmd.sh > $D/out.tmp 2>&1
                $B mv $D/out.tmp $D/out.txt
            fi
            $B sleep 2
        done
    ) &
fi
# Reports the ports servers listen on, so iSH+ forwards them
$S/bin/ishplus-agent </dev/null >/dev/null 2>&1 &
# A security key for ssh and other FIDO programs, which iSH+ answers with a
# YubiKey (or another FIDO key) over NFC
$B modprobe -q uhid; $B modprobe -q hid_generic; $B modprobe -q hidraw
$S/bin/ishplus-fido </dev/null >/dev/null 2>&1 &
# Commands sent by iSH+ (Shortcuts)
$B sh $S/boot/exec-agent.sh &
# Developer hook: run a script attached as a disk (serial "ishplus-autorun"),
# with its output on the serial port (serial.log).
for serial in /sys/block/vd*/serial; do
    [ "$($B cat "$serial" 2>/dev/null)" = ishplus-autorun ] || continue
    dev=/dev/$($B basename "$($B dirname "$serial")")
    ($B sleep 2; $B sh "$dev" > /dev/ttyAMA0 2>&1) &
done
# A root shell on each iSH+ session's console, started again when it exits.
console() {
    while [ ! -e /dev/hvc$1 ]; do $B sleep 1; done
    # With the distribution's init, the first session's return is lost:
    # that init opens the console (hvc0) before this, which delivers the
    # return early, and closing it discards it. That session connects as
    # QEMU starts, before Linux, so its shell needs no wait. The init's
    # boot messages are on that console: the shell starts once the boot is
    # done, on a cleared screen. systemd starts this early, so the shell
    # waits for it; OpenRC and sysvinit start this at the end of the boot,
    # and runit's services all start at once (boot/native.sh).
    nowait=
    [ -n "$ISHPLUS_NATIVE" ] && [ "$1" = 0 ] && nowait=1
    while :; do
        if [ -n "$nowait" ]; then
            nowait=
            if [ "$($B cat /proc/1/comm)" = systemd ]; then
                $B timeout 300 systemctl is-system-running --wait >/dev/null 2>&1
            fi
            printf '\033[H\033[2J' > /dev/hvc$1 2>/dev/null
            $B setsid -c $B sh $S/boot/shell.sh < /dev/hvc$1 > /dev/hvc$1 2>&1
            printf '\r\n[Shell exited. Press Return for a new one.]\r\n' > /dev/hvc$1 2>/dev/null
            continue
        fi
        # Output before iSH+ connects to the console is lost, and iSH+ sends
        # a return when a session connects: wait for it (without echoing
        # it), so each session sees the welcome and the first prompt. Fails
        # quietly (and is retried) while QEMU has no port for the console.
        until { $B stty -echo; read -r _; $B stty echo; } 2>/dev/null < /dev/hvc$1; do $B sleep 10; done
        $B setsid -c $B sh $S/boot/shell.sh < /dev/hvc$1 > /dev/hvc$1 2>&1
        # The shell exited (exit, or iSH+ closed the session: hangup.sh)
        printf '\r\n[Shell exited. Press Return for a new one.]\r\n' > /dev/hvc$1 2>/dev/null
    done
}
for i in 0 1 2 3; do console $i & done
while :; do wait; $B sleep 60; done

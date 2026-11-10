# iSH+'s init inside the distribution (run by tini as process 1, with the
# support disk's static busybox, so it works on any distribution): mounts,
# network, FEX, then a root shell on every iSH+ session's console. The
# distribution's own init system is not started (too heavy under emulation).
B=/opt/ishplus/bin/busybox
S=/opt/ishplus
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
mnt() { $B mountpoint -q "$3" || { $B mkdir -p "$3"; $B mount -t "$1" "$2" "$3"; }; }
mnt devpts devpts /dev/pts
mnt tmpfs tmpfs /dev/shm
mnt tmpfs tmpfs /run
mnt tmpfs tmpfs /tmp
$B mount -o remount,rw /
# Kernel modules from the modules disk, whatever the distribution ships
$B mkdir -p /lib/modules
$B mountpoint -q /lib/modules || $B mount --bind /.modloop/modules /lib/modules
# The kernel loads drivers on demand through a modprobe program, which not
# every distribution has: use busybox's
echo $S/bin/modprobe > /proc/sys/kernel/modprobe
# Drivers for the devices present (network, consoles, ...), as udev would
for alias in /sys/bus/*/devices/*/modalias; do
    $B modprobe -q "$($B cat "$alias")" 2>/dev/null
done
$B hostname ishplus
# Any user may ping (ICMP sockets need no privileges then): distributions'
# ping relies on file capabilities, which unpacking their archive loses
echo "0 2147483647" > /proc/sys/net/ipv4/ping_group_range
$B ifconfig lo up
$B ifconfig eth0 up 2>/dev/null
$B udhcpc -b -q -n -t 5 -i eth0 -s $S/boot/udhcpc.script >/dev/null 2>&1
[ -x $S/init.sh ] && $S/init.sh
# The Files app share: iSH+'s Documents/Shared folder, at /mnt/ios, and as
# iOS in the user's home
$B modprobe -q 9pnet_virtio; $B modprobe -q 9p
$B mkdir -p /mnt/ios
$B mount -t 9p -o trans=virtio,version=9p2000.L,msize=1048576,cache=mmap ishplus-share /mnt/ios 2>/dev/null
user=$($B cat /etc/ishplus/user 2>/dev/null)
home=/root
[ -n "$user" ] && home=$($B awk -F: -v u="$user" '$1 == u { print $6 }' /etc/passwd)
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
# root whenever its first line changes, output in out.txt (lets commands
# run without restarting iSH+, e.g. while switching VPNs)
if [ -d /mnt/ios/.ishplus-dev ]; then
    (
        D=/mnt/ios/.ishplus-dev; last=
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
    # Output before iSH+ connects to the console is lost, and iSH+ sends a
    # return when it connects: wait for it (without echoing it), so the
    # welcome and the first prompt are seen, once.
    until { $B stty -echo; read -r _; $B stty echo; } 2>/dev/null < /dev/hvc$1; do $B sleep 10; done
    while :; do
        # Fails quietly (and is retried) while QEMU has no port for it
        if ! { $B setsid -c $B sh $S/boot/shell.sh < /dev/hvc$1 > /dev/hvc$1 2>&1; } 2>/dev/null; then
            $B sleep 10
        fi
        $B sleep 1
    done
}
for i in 0 1 2 3; do console $i & done
while :; do wait; $B sleep 60; done

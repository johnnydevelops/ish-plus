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
$B ifconfig lo up
$B ifconfig eth0 up 2>/dev/null
$B udhcpc -b -q -n -t 5 -i eth0 -s $S/boot/udhcpc.script >/dev/null 2>&1
[ -x $S/init.sh ] && $S/init.sh
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

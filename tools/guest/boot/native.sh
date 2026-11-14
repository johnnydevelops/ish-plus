# Booting a distribution with its own init system (kernel argument
# ishplus.init=native), run by the initramfs before switch_root with the
# distribution at $1 (its mounts already moved there): prepares what iSH+'s
# own init (main.sh) would otherwise do as process 1, and installs iSH+'s
# part (main.sh as a service: consoles, Files share, ports, security key)
# into the init system. Prints the init to start; fails (and iSH+'s own init
# boots instead) for an init system it does not know (systemd, OpenRC,
# runit and sysvinit are known).
R=$1
S=/opt/ishplus
# The command that starts iSH+'s part, for init systems that take one
MAIN="$S/bin/busybox env ISHPLUS_NATIVE=1 $S/bin/busybox sh $S/boot/main.sh"

# The kernel modules disk on the distribution's module directory (/lib may
# be a link to /usr/lib)
lib=$R/lib
[ -L "$lib" ] && lib=$R/usr/lib
mkdir -p "$lib/modules"
mountpoint -q "$lib/modules" || mount --bind "$R/.modloop/modules" "$lib/modules"
# Drivers for the devices present (network, consoles, ...), as main.sh
# loads them: images for containers may have no udev (Devuan's), and their
# network setup would find no eth0. Not the display and its input (the
# Desktop session loads them).
chroot "$R" $S/bin/busybox sh -c 'for alias in /sys/bus/*/devices/*/modalias; do
    a=$('$S'/bin/busybox cat "$alias")
    case "$a" in virtio:d00000010v*|virtio:d00000012v*) continue ;; esac
    '$S'/bin/busybox modprobe -q "$a" 2>/dev/null
done'

# The network device keeps its kernel name, eth0, which distribution images
# for containers configure: udev would rename it (to enp0s4), systemd's
# udev by its default link file (also without systemd, as on Devuan),
# eudev (Void) by its rule
mkdir -p "$R/etc/systemd/network" "$R/etc/udev/rules.d"
ln -sf /dev/null "$R/etc/systemd/network/99-default.link"
ln -sf /dev/null "$R/etc/udev/rules.d/80-net-name-slot.rules"

# Which of these paths the distribution has. Tested in its root, where a
# link may point outside it (/sbin/init -> /bin/busybox): the link counts.
has() {
    for f; do
        if [ -e "$R$f" ] || [ -L "$R$f" ]; then echo "$f"; return 0; fi
    done
    return 1
}
# Inits with an inittab (busybox's, sysvinit's): iSH+'s consoles are its
# sessions' shells and the serial port is its boot log (serial.log), so no
# logins on them ("console" is hvc0, the kernel's last console=). Commented
# out rather than deleted, so they can be restored.
inittab() {
    [ -f "$R/etc/inittab" ] || return 0
    sed -i -E '/^[^#].*getty.*(hvc[0-9]|ttyAMA0|console)([[:space:]]|$)/s/^/#ishplus# /' "$R/etc/inittab"
}

# systemd
for sd in /usr/lib/systemd/systemd /lib/systemd/systemd; do
    [ -x "$R$sd" ] || continue
    U=$R/etc/systemd/system
    mkdir -p "$U/sysinit.target.d"
    cat > "$U/ishplus.service" <<EOF
# Installed by iSH+ at every boot with ishplus.init=native (tools/guest/boot/native.sh)
[Unit]
Description=iSH+ (consoles, Files share, ports, security key)
DefaultDependencies=no
After=local-fs.target systemd-tmpfiles-setup.service
Before=sysinit.target

[Service]
Type=simple
Environment=ISHPLUS_NATIVE=1
ExecStart=$S/bin/busybox sh $S/boot/main.sh
Restart=always
# The shells on iSH+'s consoles are its children: not stopped with it
KillMode=process
EOF
    # Started by a drop-in, not an enablement link: on first boot systemd
    # applies the distribution's presets, which remove the links of units
    # they disable (Fedora's disable everything not listed)
    rm -f "$U/sysinit.target.wants/ishplus.service"
    printf '[Unit]\nWants=ishplus.service\n' > "$U/sysinit.target.d/ishplus.conf"
    # iSH+'s consoles are its sessions' shells: no logins on them (the
    # kernel's console=hvc0 would start one), and the serial port is
    # iSH+'s boot log (serial.log), not a terminal. Those logins are made by
    # the getty generator, turned off here (the masks alone are removed by
    # the first boot's presets, with serial-getty@.service disabled).
    for i in 0 1 2 3 4 5 6 7; do ln -sf /dev/null "$U/serial-getty@hvc$i.service"; done
    ln -sf /dev/null "$U/serial-getty@ttyAMA0.service"
    mkdir -p "$R/etc/systemd/system-generators"
    ln -sf /dev/null "$R/etc/systemd/system-generators/systemd-getty-generator"
    # Boot progress on the first session's console, for following and
    # debugging the boot (main.sh clears it before the shell)
    mkdir -p "$R/etc/systemd/system.conf.d"
    printf '[Manager]\nShowStatus=yes\n' > "$R/etc/systemd/system.conf.d/ishplus.conf"
    echo "$sd"
    exit 0
done

# runit (Void): a service, started with all the others in runit's second
# stage (runit has no later "boot done" point to wait for); runsv starts it
# again if it ends, and stops only it (the shells on iSH+'s consoles are
# its children)
if init=$(has /usr/bin/runit-init /sbin/runit-init) && [ -d "$R/etc/runit/runsvdir/default" ]; then
    mkdir -p "$R/etc/sv/ishplus"
    cat > "$R/etc/sv/ishplus/run" <<EOF
#!/bin/sh
# Installed by iSH+ at every boot with ishplus.init=native (tools/guest/boot/native.sh)
exec $MAIN
EOF
    chmod 755 "$R/etc/sv/ishplus/run"
    ln -sfn /etc/sv/ishplus "$R/etc/runit/runsvdir/default/ishplus"
    # No logins on iSH+'s consoles ("console" is hvc0) or the serial log
    for tty in console hvc0 hvc1 hvc2 hvc3 hvc4 hvc5 hvc6 hvc7 ttyAMA0 serial; do
        rm -f "$R/etc/runit/runsvdir/default/agetty-$tty"
    done
    echo "$init"
    exit 0
fi

# OpenRC (Alpine, Gentoo...): a service of the default run level, after all
# the others, so the first session's shell starts once the boot is done;
# supervise-daemon starts it again if it ends, and stops only it
if openrc_run=$(has /sbin/openrc-run /usr/sbin/openrc-run /usr/bin/openrc-run); then
    cat > "$R/etc/init.d/ishplus" <<EOF
#!$openrc_run
# Installed by iSH+ at every boot with ishplus.init=native (tools/guest/boot/native.sh)
description="iSH+ (consoles, Files share, ports, security key)"
supervisor=supervise-daemon
command=$S/bin/busybox
command_args="${MAIN#$S/bin/busybox }"
depend() {
    after *
}
EOF
    chmod 755 "$R/etc/init.d/ishplus"
    mkdir -p "$R/etc/runlevels/default"
    ln -sf /etc/init.d/ishplus "$R/etc/runlevels/default/ishplus"
    inittab
    # Run by busybox's or sysvinit's init from the inittab (Alpine), or by
    # OpenRC's own init
    if [ -f "$R/etc/inittab" ] && init=$(has /sbin/init /usr/sbin/init); then
        echo "$init"
    else
        has /sbin/openrc-init /usr/sbin/openrc-init /usr/bin/openrc-init || exit 1
    fi
    exit 0
fi

# sysvinit (Devuan): an inittab entry after the run level's, whose scripts
# init runs (and waits for) first, so the first session's shell starts once
# the boot is done; init starts it again if it ends. Replaced at every boot.
if [ -f "$R/etc/inittab" ] && init=$(has /sbin/init /usr/sbin/init); then
    inittab
    sed -i '/^ishp:/d' "$R/etc/inittab"
    echo "ishp:2345:respawn:$MAIN" >> "$R/etc/inittab"
    echo "$init"
    exit 0
fi
exit 1

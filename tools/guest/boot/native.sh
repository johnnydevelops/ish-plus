# Booting a distribution with its own init system (kernel argument
# ishplus.init=native), run by the initramfs before switch_root with the
# distribution at $1 (its mounts already moved there): prepares what iSH+'s
# own init (main.sh) would otherwise do as process 1, and installs iSH+'s
# part (main.sh as a service: consoles, Files share, ports, security key)
# into the init system. Prints the init to start; fails (and iSH+'s own init
# boots instead) for an init system it does not know.
R=$1
S=/opt/ishplus

# The kernel modules disk on the distribution's module directory (/lib may
# be a link to /usr/lib)
lib=$R/lib
[ -L "$lib" ] && lib=$R/usr/lib
mkdir -p "$lib/modules"
mountpoint -q "$lib/modules" || mount --bind "$R/.modloop/modules" "$lib/modules"

# systemd
for sd in /usr/lib/systemd/systemd /lib/systemd/systemd; do
    [ -x "$R$sd" ] || continue
    U=$R/etc/systemd/system
    mkdir -p "$U/sysinit.target.wants"
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

[Install]
WantedBy=sysinit.target
EOF
    ln -sf ../ishplus.service "$U/sysinit.target.wants/ishplus.service"
    # iSH+'s consoles are its sessions' shells: no logins on them (the
    # kernel's console=hvc0 would start one)
    for i in 0 1 2 3 4 5 6 7; do ln -sf /dev/null "$U/serial-getty@hvc$i.service"; done
    # The serial port is iSH+'s boot log (serial.log), not a terminal
    ln -sf /dev/null "$U/serial-getty@ttyAMA0.service"
    # Boot progress on the first session's console, for following and
    # debugging the boot (main.sh clears it before the shell)
    mkdir -p "$R/etc/systemd/system.conf.d"
    printf '[Manager]\nShowStatus=yes\n' > "$R/etc/systemd/system.conf.d/ishplus.conf"
    # The network device keeps its kernel name, eth0, which distribution
    # images for containers configure (udev would rename it to enp0s4)
    mkdir -p "$R/etc/systemd/network"
    ln -sf /dev/null "$R/etc/systemd/network/99-default.link"
    echo "$sd"
    exit 0
done
exit 1

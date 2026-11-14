# The Desktop session: an X11 session (Xorg) or a Wayland compositor on the
# VM's display (virtio-gpu), with the virtio tablet, mouse and keyboard iSH+
# sends touches and keys to, and the desktops or window managers the user
# installed. iSH+ runs it as root through the exec agent:
#   desktop.sh list         every session that can start here, one per line:
#                           "<id>\t<x11|wayland>\t<name>", X11 ones first
#   desktop.sh check        prints the default session's name (exit 1: none)
#   desktop.sh start [ID]   starts that session (stopping another one first);
#                           without ID, the last one started or the default,
#                           unless one is running
#   desktop.sh current      prints the running session's id
#   desktop.sh resize       uses the size iSH+ offers now
#   desktop.sh stop         ends the session
# A session's id is its file's name (/usr/share/xsessions/xfce.desktop: xfce,
# /usr/share/wayland-sessions/sway.desktop: sway; "-wayland" is added when an
# X11 session has the same), or a window manager's without a session file.
# start ID remembers it in /etc/ishplus/desktop-session. The default is the
# first X11 session (desktops first, then window managers), else the first
# Wayland one.
#
# Wayland compositors need a seat (access to the display and input): with
# iSH+'s own init, seatd (package seatd), which this starts; with the
# distribution's systemd (the default boot), logind. GNOME and KDE Plasma
# on Wayland need logind and systemd's user services, so they are offered
# only with systemd.
B=/opt/ishplus/bin/busybox
R=/run/ishplus-desktop
CHOICE=/etc/ishplus/desktop-session
TAB=$(printf '\t')
user=$($B cat /etc/ishplus/user 2>/dev/null)

xorg() {
    for x in /usr/lib/xorg/Xorg /usr/libexec/Xorg /usr/lib/Xorg /usr/bin/Xorg; do
        [ -x "$x" ] && { echo "$x"; return 0; }
    done
    return 1
}

# Xorg needs its modesetting driver and an input driver (libinput or
# evdev): xorg_driver drivers|input NAME
xorg_driver() {
    for d in /usr/lib/xorg/modules /usr/lib64/xorg/modules /usr/lib/*/xorg/modules; do
        [ -e "$d/$1/$2_drv.so" ] && return 0
    done
    return 1
}

x11_ok() {
    xorg >/dev/null && xorg_driver drivers modesetting && { xorg_driver input libinput || xorg_driver input evdev; }
}

# logind manages the seat (the distribution's systemd runs)
logind() {
    [ -d /run/systemd/seats ] && [ "$($B cat /proc/1/comm 2>/dev/null)" = systemd ]
}

seatd_bin() {
    command -v seatd 2>/dev/null && return 0
    for s in /usr/sbin/seatd /usr/bin/seatd /sbin/seatd; do
        [ -x "$s" ] && { echo "$s"; return 0; }
    done
    return 1
}

# A key of a session file's [Desktop Entry] (not a translation)
field() {
    $B sed -n "s/^$2=//p" "$1" | $B head -1
}

# One session: "<rank>\t<id>\t<type>\t<name>\t<command>\t<desktop names>"
# (rank: the default's order; returns 1 if it cannot start here)
entry() { # file x11|wayland
    cmd=$(field "$1" Exec); name=$(field "$1" Name); tryexec=$(field "$1" TryExec)
    [ -n "$cmd" ] && [ -n "$name" ] || return 1
    [ "$(field "$1" Hidden)" = true ] && return 1
    prog=${tryexec:-${cmd%% *}}
    command -v "$prog" >/dev/null 2>&1 || [ -x "$prog" ] || return 1
    id=$($B basename "$1" .desktop)
    desktops=$(field "$1" DesktopNames | $B tr ';' ':'); desktops=${desktops%:}
    if [ "$2" = x11 ]; then
        case "$id" in
            xfce*) rank=1 ;; mate*) rank=2 ;; lxqt*) rank=3 ;; LXDE*|lxde*) rank=4 ;;
            cinnamon*) rank=5 ;; plasma*|kde*) rank=6 ;; *gnome*|*ubuntu*) rank=20 ;;
            *) rank=10 ;;
        esac
        x11_ids="$x11_ids $id "
    else
        # GNOME, KDE Plasma and desktops built on them need logind
        case "$id $cmd" in
            *gnome*|*ubuntu*|*plasma*|*kde*|*cosmic*|*budgie*|*cinnamon*|*pantheon*) logind || return 1 ;;
        esac
        logind || seatd_bin >/dev/null || return 1
        # Sessions that run in a compositor installed separately (Xfce and
        # LXQt on Wayland): only with one of those it can use
        case "$cmd" in
            *startxfce4*) needs="labwc wayfire" ;;
            *startlxqtwayland*|*lxqt-wayland*) needs="labwc kwin_wayland wayfire sway niri Hyprland" ;;
            *) needs= ;;
        esac
        if [ -n "$needs" ]; then
            found=
            for compositor in $needs; do command -v "$compositor" >/dev/null 2>&1 && found=1; done
            [ -n "$found" ] || return 1
        fi
        case "$x11_ids" in *" $id "*) id=$id-wayland ;; esac
        case "$id" in
            plasma*|kde*) rank=1 ;; gnome*|ubuntu*) rank=2 ;; xfce*) rank=3 ;; cosmic*) rank=4 ;;
            labwc*) rank=5 ;; sway*) rank=6 ;; wayfire*) rank=7 ;; hyprland*|Hyprland*) rank=8 ;;
            weston*) rank=9 ;; *) rank=10 ;;
        esac
        rank=$((rank + 100))
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$rank" "$id" "$2" "$name" "$cmd" "$desktops"
}

# Every session that can start, in the default's order: sessions in
# /usr/share/xsessions (desktops first, GNOME last: it needs systemd), else
# window managers without one; then /usr/share/wayland-sessions.
sessions() {
    x11_ids=""
    {
        if x11_ok; then
            any=""
            for f in /usr/share/xsessions/*.desktop; do
                [ -e "$f" ] && entry "$f" x11 && any=1
            done
            if [ -z "$any" ]; then
                seen=" "
                for wm in openbox-session:openbox openbox:openbox i3:i3 xfwm4:xfwm4 fluxbox:fluxbox \
                          icewm-session:icewm icewm:icewm jwm:jwm awesome:awesome herbstluftwm:herbstluftwm \
                          fvwm3:fvwm fvwm:fvwm wmaker:wmaker twm:twm; do
                    prog=${wm%%:*}; id=${wm#*:}
                    case "$seen" in *" $id "*) continue ;; esac
                    command -v "$prog" >/dev/null 2>&1 || continue
                    seen="$seen$id "
                    printf '50\t%s\tx11\t%s\t%s\t\n' "$id" "$id" "$prog"
                done
            fi
        fi
        for f in /usr/share/wayland-sessions/*.desktop; do
            [ -e "$f" ] && entry "$f" wayland
        done
    } | $B sort -s -n -t "$TAB" -k1,1
}

list() {
    sessions | $B cut -f2-4
}

lookup() { # id
    sessions | $B awk -F "$TAB" -v id="$1" '$2 == id { print; found = 1; exit } END { exit !found }'
}

# The remembered session if it can still start, else the first
default_session() {
    last=$($B cat $CHOICE 2>/dev/null)
    [ -n "$last" ] && lookup "$last" && return 0
    s=$(sessions | $B head -1)
    [ -n "$s" ] && echo "$s"
}

# Why nothing can start
nothing() {
    if $B ls /usr/share/wayland-sessions/*.desktop >/dev/null 2>&1 && ! logind && ! seatd_bin >/dev/null; then
        echo "Wayland sessions need seatd here (install the package seatd), or the distribution's systemd."
    elif $B ls /usr/share/xsessions/*.desktop >/dev/null 2>&1 && ! xorg >/dev/null; then
        echo "Xorg is not installed."
    else
        echo "No desktop or window manager is installed."
    fi
}

check() {
    d=$(default_session) && echo "$d" | $B cut -f4
}

running() {
    [ -f $R/server.pid ] && $B kill -0 "$($B cat $R/server.pid)" 2>/dev/null
}

current() {
    running && $B cat $R/current 2>/dev/null
    return 0
}

udevd_bin() {
    for u in /usr/lib/systemd/systemd-udevd /lib/systemd/systemd-udevd /sbin/udevd /usr/sbin/udevd \
             /usr/bin/udevd /usr/lib/udev/udevd; do
        [ -x "$u" ] && { echo "$u"; return 0; }
    done
    return 1
}

# udev: what Xorg, compositors and libinput learn the devices from, and how
# compositors hear that the display's size changed (a hotplug event). With
# iSH+'s own init no udev daemon runs: start the distribution's (only for
# the display and input devices), or else write what it would record.
udev() {
    if [ ! -S /run/udev/control ] && u=$(udevd_bin); then
        $B mkdir -p /run/udev
        "$u" --daemon >/dev/null 2>&1
        i=0; while [ ! -S /run/udev/control ] && [ $i -lt 30 ]; do $B sleep 0.1; i=$((i + 1)); done
        if [ -S /run/udev/control ]; then
            udevadm trigger --action=add --subsystem-match=drm --subsystem-match=input >/dev/null 2>&1
            udevadm settle -t 5 >/dev/null 2>&1
        fi
    fi
    [ -S /run/udev/control ] || udev_db
}

# What udev would record for the display and input devices
udev_db() {
    $B mkdir -p /run/udev/data /run/udev/tags/seat
    for dev in /sys/class/input/event* /sys/class/drm/card[0-9]; do
        [ -e "$dev/dev" ] || continue
        node="c$($B cat "$dev/dev")"
        name=$($B cat "$dev/device/name" 2>/dev/null)
        {
            case "$dev" in
                */input/*)
                    echo "E:ID_INPUT=1"
                    case "$name" in
                        *[Kk]eyboard*) echo "E:ID_INPUT_KEY=1"; echo "E:ID_INPUT_KEYBOARD=1" ;;
                        *[Kk]eys*) echo "E:ID_INPUT_KEY=1" ;;
                        *) echo "E:ID_INPUT_MOUSE=1" ;;
                    esac ;;
                *) echo "G:master-of-seat"; echo "Q:master-of-seat" ;;
            esac
            echo "G:seat"; echo "Q:seat"
        } > /run/udev/data/$node
        : > /run/udev/tags/seat/$node
    done
}

# The GPU has 3D (iSH+'s GPU acceleration: virgl, and venus with it), and
# Mesa has its driver: Xorg then draws with OpenGL (glamor), which also gives
# the desktop's programs OpenGL. Otherwise it draws in software. (The render
# node exists without 3D too; the driver's debugfs features tell.)
gpu_3d() {
    [ -e /dev/dri/renderD128 ] || return 1
    f=$($B ls /sys/kernel/debug/dri/*/virtio-gpu-features 2>/dev/null | $B head -1)
    if [ -z "$f" ]; then
        $B mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null
        f=$($B ls /sys/kernel/debug/dri/*/virtio-gpu-features 2>/dev/null | $B head -1)
    fi
    if [ -n "$f" ]; then
        $B grep -Eq '^virgl +: yes' "$f" || return 1
    else
        $B dmesg | $B grep -q 'features: +virgl' || return 1
    fi
    for d in /usr/lib/*/dri /usr/lib/dri /usr/lib64/dri; do
        [ -e "$d/virtio_gpu_dri.so" ] && return 0
    done
    return 1
}

# The display and input devices, ready for Xorg or a compositor
devices() {
    # The display and input drivers (not loaded at boot, to save memory)
    $B modprobe -q virtio_input; $B modprobe -q evdev; $B modprobe -q virtio-gpu
    i=0; while [ ! -e /dev/dri/card0 ] && [ $i -lt 50 ]; do $B sleep 0.1; i=$((i + 1)); done
    $B sleep 0.5
    udev
    # The GPU for the user's programs (OpenGL and Vulkan: virgl, zink, Venus),
    # as udev's rules would (render node for everyone, card for "video");
    # devtmpfs makes them root's only
    $B chmod 0666 /dev/dri/renderD* 2>/dev/null
    $B chgrp video /dev/dri/card* 2>/dev/null && $B chmod 0660 /dev/dri/card* 2>/dev/null
}

# The display's connector (/sys/class/drm/card0-Virtual-1)
connector() {
    for c in /sys/class/drm/card[0-9]-*; do
        [ "$($B cat "$c/status" 2>/dev/null)" = connected ] && { echo "$c"; return 0; }
    done
    return 1
}

# Pointer acceleration off by default (see xorg.conf below), in each
# compositor's system-wide settings, which the user's own replace: files
# marked iSH+'s are kept up to date, others are left alone
mine() {
    [ ! -e "$1" ] || $B grep -q 'iSH+' "$1"
}
put() { # file (contents on stdin), if it is iSH+'s and changed
    mine "$1" || return 1
    $B mkdir -p "$($B dirname "$1")"
    new=$($B cat)
    [ "$new" = "$($B cat "$1" 2>/dev/null)" ] && return 1
    echo "$new" > "$1"
}
accel_defaults() {
    note="No pointer acceleration (iSH+'s default: iPadOS already accelerates)."
    if [ -d /etc/sway ]; then
        put /etc/sway/config.d/50-ishplus-pointer.conf <<EOF
# $note
# Your own ~/.config/sway/config replaces this, or set it after its include.
input type:pointer {
    accel_profile flat
    pointer_accel 0
}
EOF
    fi
    if command -v labwc >/dev/null 2>&1; then
        put /etc/xdg/labwc/rc.xml <<EOF
<?xml version="1.0"?>
<!-- $note Your own ~/.config/labwc/rc.xml replaces this file. -->
<labwc_config>
  <libinput>
    <device category="default">
      <accelProfile>flat</accelProfile>
      <pointerSpeed>0</pointerSpeed>
    </device>
  </libinput>
</labwc_config>
EOF
    fi
    if command -v weston >/dev/null 2>&1; then
        put /etc/xdg/weston/weston.ini <<EOF
# $note
# Your own ~/.config/weston.ini replaces this file.
[libinput]
accel-profile=flat
EOF
    fi
    if command -v gnome-shell >/dev/null 2>&1; then
        if command -v dconf >/dev/null 2>&1; then
            if put /etc/dconf/db/ishplus.d/00-pointer <<EOF
# $note
[org/gnome/desktop/peripherals/mouse]
accel-profile='flat'
EOF
            then
                $B grep -qs '^system-db:ishplus$' /etc/dconf/profile/user || {
                    $B mkdir -p /etc/dconf/profile
                    [ -s /etc/dconf/profile/user ] || echo "user-db:user" > /etc/dconf/profile/user
                    echo "system-db:ishplus" >> /etc/dconf/profile/user
                }
                dconf update 2>/dev/null
            fi
        elif put /usr/share/glib-2.0/schemas/90_ishplus-pointer.gschema.override <<EOF
# $note
[org.gnome.desktop.peripherals.mouse]
accel-profile='flat'
EOF
        then
            glib-compile-schemas /usr/share/glib-2.0/schemas 2>/dev/null
        fi
    fi
    if command -v kwin_wayland >/dev/null 2>&1; then
        # Per device: QEMU's vendor 0x627 (1575), mouse 2, tablet 3; 1 is flat
        put /etc/xdg/kcminputrc <<EOF
# $note
[Libinput][1575][2][QEMU Virtio Mouse]
PointerAccelerationProfile=1

[Libinput][1575][3][QEMU Virtio Tablet]
PointerAccelerationProfile=1
EOF
    fi
}

# A display manager running (its login screen; boot/native.sh keeps them
# from starting at boot, but one may have started before that, or by hand):
# stopped, so the session gets the display and starts without a login
stop_display_managers() {
    for dm in lightdm gdm gdm3 sddm lxdm slim xdm greetd ly nodm; do
        $B pgrep -x "$dm" >/dev/null 2>&1 || continue
        if [ "$($B cat /proc/1/comm)" = systemd ]; then
            systemctl stop display-manager.service "$dm.service" 2>/dev/null
        else
            rc-service "$dm" stop 2>/dev/null || sv down "$dm" 2>/dev/null || /etc/init.d/"$dm" stop 2>/dev/null
        fi
        $B pkill -x "$dm" 2>/dev/null
    done
}

start() {
    if [ -n "$1" ]; then
        s=$(lookup "$1") || { echo "There is no desktop session \"$1\" here."; return 1; }
    else
        # Already running (started before the Desktop was shown): take the
        # size iSH+ offers now instead of the one it started with
        running && { resize; return 0; }
        s=$(default_session) || { nothing; return 1; }
    fi
    id=$(echo "$s" | $B cut -f2); type=$(echo "$s" | $B cut -f3)
    session=$(echo "$s" | $B cut -f5); desktops=$(echo "$s" | $B cut -f6)
    if running; then
        [ "$($B cat $R/current 2>/dev/null)" = "$id" ] && { resize; return 0; }
        stop
    fi
    [ -n "$1" ] && { $B mkdir -p /etc/ishplus; echo "$id" > $CHOICE; }
    $B mkdir -p $R
    stop_display_managers
    devices
    who=${user:-root}
    uid=$($B id -u "$who"); gid=$($B id -g "$who")
    echo "$uid" > $R/uid
    $B mkdir -p /run/user/$uid && $B chown "$uid:$gid" /run/user/$uid && $B chmod 700 /run/user/$uid
    if [ "$type" = x11 ]; then
        start_x11 || return 1
    else
        start_wayland || return 1
    fi
    echo "$id" > $R/current
    echo "$type" > $R/type
    resize
    return 0
}

start_x11() {
    xorg=$(xorg)
    accel=none
    gpu_3d && accel=glamor
    echo "$accel" > $R/accel
    cat > $R/xorg.conf <<EOF
Section "ServerFlags"
    Option "AutoAddGPU" "false"
    Option "BlankTime" "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime" "0"
EndSection
Section "Device"
    Identifier "iSH+ display"
    Driver "modesetting"
    Option "AccelMethod" "$accel"
EndSection
# No pointer acceleration: the iPad's trackpad, a captured mouse and the
# laptop mode's trackpad move the pointer by what they report, as iPadOS
# already accelerated it (twice is awkward). A setting in xorg.conf.d,
# read after this, still wins.
Section "InputClass"
    Identifier "iSH+ pointer"
    MatchIsPointer "on"
    Option "AccelProfile" "flat"
    Option "AccelSpeed" "0"
EndSection
EOF
    # Xorg allows -config only in its own directories, or as root
    setsid "$xorg" :0 vt7 -nolisten tcp -noreset -s 0 -dpms -config $R/xorg.conf \
        -logfile $R/Xorg.log </dev/null >$R/xorg.out 2>&1 &
    echo $! > $R/server.pid
    i=0; while [ ! -e /tmp/.X11-unix/X0 ] && [ $i -lt 100 ]; do
        running || { echo "Xorg did not start:"; $B grep "(EE)" $R/Xorg.log | $B tail -5; return 1; }
        $B sleep 0.2; i=$((i + 1))
    done
    # The desktop, as the user, with its own D-Bus session if there is D-Bus
    wrap=""
    command -v dbus-run-session >/dev/null 2>&1 && wrap="dbus-run-session --"
    [ -z "$wrap" ] && command -v dbus-launch >/dev/null 2>&1 && wrap="dbus-launch --exit-with-session"
    cat > $R/session <<EOF
#!/bin/sh
export DISPLAY=:0 XDG_RUNTIME_DIR=/run/user/$uid XDG_SESSION_TYPE=x11 ISHPLUS_DESKTOP=$id
[ -n "$desktops" ] && export XDG_CURRENT_DESKTOP=$desktops XDG_SESSION_DESKTOP=$id
cd
# A background for bare window managers (desktops draw their own)
command -v xsetroot >/dev/null 2>&1 && xsetroot -solid '#2b3a4a'
# Sound without systemd's user services (which start it otherwise): the
# sound server the distribution has, PipeWire or PulseAudio
if [ ! -S "\$XDG_RUNTIME_DIR/bus" ]; then
    if command -v pipewire >/dev/null 2>&1; then
        pipewire >/dev/null 2>&1 &
        sleep 1
        command -v wireplumber >/dev/null 2>&1 && wireplumber >/dev/null 2>&1 &
        command -v pipewire-pulse >/dev/null 2>&1 && pipewire-pulse >/dev/null 2>&1 &
    elif command -v pulseaudio >/dev/null 2>&1; then
        pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1
    fi
fi
# With systemd's user services (logind), their D-Bus session: snap runs its
# applications through them (systemd-run --user), and a session of its own
# would hide them ("cannot run snap applications on this system")
if [ -S "\$XDG_RUNTIME_DIR/bus" ]; then
    export DBUS_SESSION_BUS_ADDRESS=unix:path=\$XDG_RUNTIME_DIR/bus
    exec $session
fi
exec $wrap $session
EOF
    $B chmod 755 $R/session
    # With logind: a user session on seat0 and Xorg's vt7 (pam_systemd,
    # through su), as a display manager makes, not a background one
    seat=""
    logind && seat="XDG_SEAT=seat0 XDG_VTNR=7 XDG_SESSION_CLASS=user XDG_SESSION_TYPE=x11 XDG_SESSION_DESKTOP=$id"
    if [ "$who" = root ]; then
        setsid env $seat sh -lc $R/session </dev/null >$R/session.log 2>&1 &
    else
        setsid env $seat su -l "$who" -c $R/session </dev/null >$R/session.log 2>&1 &
    fi
    echo $! > $R/session.pid
}

start_wayland() {
    accel_defaults
    seat=""
    if logind; then
        # A logind session on seat0 (pam_systemd, through su), on its own
        # virtual terminal (as Xorg's vt7), made the active one, which lets
        # the compositor take the display and input devices
        seat="XDG_SEAT=seat0 XDG_VTNR=7 XDG_SESSION_CLASS=user XDG_SESSION_TYPE=wayland XDG_SESSION_DESKTOP=$id"
        $B chvt 7 2>/dev/null
    else
        # seatd, as root, lets the user's compositor open them (seatd-launch
        # would not: it runs both as the user calling it)
        if [ ! -S /run/seatd.sock ]; then
            group=$($B id -gn "$who")
            setsid "$(seatd_bin)" -u "$who" -g "$group" -l error </dev/null >$R/seatd.log 2>&1 &
            echo $! > $R/seatd.pid
            i=0; while [ ! -S /run/seatd.sock ] && [ $i -lt 50 ]; do $B sleep 0.1; i=$((i + 1)); done
            [ -S /run/seatd.sock ] || { echo "seatd did not start:"; $B tail -3 $R/seatd.log; return 1; }
        fi
    fi
    # Software rendering without the GPU's 3D: Pixman for wlroots and
    # Weston (cheaper than OpenGL on llvmpipe)
    renderer=""
    gpu_3d || renderer="export WLR_RENDERER=pixman"
    case "$id" in weston*) gpu_3d || session="$session --renderer=pixman" ;; esac
    cat > $R/session <<EOF
#!/bin/sh
export XDG_RUNTIME_DIR=/run/user/$uid XDG_SESSION_TYPE=wayland XDG_SESSION_DESKTOP=$id ISHPLUS_DESKTOP=$id
[ -n "$desktops" ] && export XDG_CURRENT_DESKTOP=$desktops
export LIBSEAT_BACKEND=$([ -n "$seat" ] && echo logind || echo seatd)
$renderer
unset DISPLAY WAYLAND_DISPLAY
cd
# Sound without systemd's user services (which start it otherwise): the
# sound server the distribution has, PipeWire or PulseAudio
if [ ! -S "\$XDG_RUNTIME_DIR/bus" ]; then
    if command -v pipewire >/dev/null 2>&1; then
        pipewire >/dev/null 2>&1 &
        sleep 1
        command -v wireplumber >/dev/null 2>&1 && wireplumber >/dev/null 2>&1 &
        command -v pipewire-pulse >/dev/null 2>&1 && pipewire-pulse >/dev/null 2>&1 &
    elif command -v pulseaudio >/dev/null 2>&1; then
        pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1
    fi
fi
# With systemd's user services (logind), their D-Bus session; otherwise one
# of its own, if there is D-Bus
if [ -S "\$XDG_RUNTIME_DIR/bus" ] || ! command -v dbus-run-session >/dev/null 2>&1; then
    exec $session
fi
exec dbus-run-session -- $session
EOF
    $B chmod 755 $R/session
    $B rm -f $R/wayland
    sockets() { $B ls /run/user/$uid 2>/dev/null | $B grep -E '^wayland-[0-9]+$'; }
    before=" $(sockets | $B tr '\n' ' ')"
    setsid env $seat su -l "$who" -c $R/session </dev/null >$R/session.log 2>&1 &
    echo $! > $R/server.pid
    echo $! > $R/session.pid
    # Up when its socket appears
    i=0
    while [ $i -lt 150 ]; do
        running || { echo "The session ended:"; $B tail -5 $R/session.log; return 1; }
        for w in $(sockets); do
            case "$before" in *" $w "*) ;; *) echo "$w" > $R/wayland; return 0 ;; esac
        done
        $B sleep 0.2; i=$((i + 1))
    done
    return 0
}

# virtio-gpu offers iSH+'s size as the preferred mode. X11: set it (needs
# xrandr; Xorg does not switch by itself). Wayland: the connector is probed
# again (its first mode is the preferred one) and the compositor told:
# sway (swaymsg) or other wlroots compositors (wlr-randr); GNOME and KDE
# follow virtio-gpu's preferred mode themselves (hotplug_mode_update)
resize() {
    running || return 1
    if [ "$($B cat $R/type 2>/dev/null)" = wayland ]; then
        resize_wayland
        return 0
    fi
    command -v xrandr >/dev/null 2>&1 || return 0
    output=$(DISPLAY=:0 xrandr 2>/dev/null | $B awk '/ connected/ { print $1; exit }')
    [ -n "$output" ] && DISPLAY=:0 xrandr --output "$output" --auto >/dev/null 2>&1
    return 0
}

resize_wayland() {
    # GNOME and KDE Plasma switch by themselves; Weston keeps the size it
    # started with
    case "$($B cat $R/current 2>/dev/null)" in gnome*|ubuntu*|plasma*|kde*|weston*) return 0 ;; esac
    c=$(connector) || return 0
    echo detect > "$c/status" 2>/dev/null
    mode=$($B head -1 "$c/modes")
    [ -n "$mode" ] || return 0
    output=${c##*/card[0-9]-}
    uid=$($B cat $R/uid)
    export XDG_RUNTIME_DIR=/run/user/$uid
    WAYLAND_DISPLAY=$($B cat $R/wayland 2>/dev/null); export WAYLAND_DISPLAY
    sock=$($B ls /run/user/$uid/sway-ipc.*.sock 2>/dev/null | $B tail -1)
    # As a custom mode: wlroots keeps the modes it found when the
    # compositor started (and sway quietly ignores a mode not among them)
    if [ -n "$sock" ] && command -v swaymsg >/dev/null 2>&1; then
        swaymsg -s "$sock" -- output "$output" mode --custom "$mode" >/dev/null 2>&1
    elif command -v wlr-randr >/dev/null 2>&1 && [ -n "$WAYLAND_DISPLAY" ]; then
        wlr-randr --output "$output" --custom-mode "$mode" >/dev/null 2>&1
    fi
    return 0
}

# Every program of the session (they have its ISHPLUS_DESKTOP, or X11's
# DISPLAY)
desktop_pids() {
    for p in /proc/[0-9]*; do
        [ "${p#/proc/}" = "$$" ] && continue
        { $B tr '\0' '\n' < "$p/environ"; } 2>/dev/null | $B grep -qE '^(DISPLAY=:0|ISHPLUS_DESKTOP=.*)$' && echo "${p#/proc/}"
    done
}

stop() {
    # A logind session ends with its services (GNOME's, KDE's)
    if logind && [ -f $R/session.pid ]; then
        sid=$($B sed -n 's|.*/session-\([^/]*\)\.scope.*|\1|p' "/proc/$($B cat $R/session.pid)/cgroup" 2>/dev/null | $B head -1)
        [ -n "$sid" ] && loginctl terminate-session "$sid" 2>/dev/null
    fi
    pids=$(desktop_pids)
    [ -n "$pids" ] && $B kill $pids 2>/dev/null
    [ -f $R/server.pid ] && $B kill "$($B cat $R/server.pid)" 2>/dev/null
    $B sleep 1
    pids=$(desktop_pids)
    [ -n "$pids" ] && $B kill -9 $pids 2>/dev/null
    [ -f $R/server.pid ] && $B kill -9 "$($B cat $R/server.pid)" 2>/dev/null
    [ -f $R/seatd.pid ] && $B kill "$($B cat $R/seatd.pid)" 2>/dev/null
    $B rm -f $R/server.pid $R/session.pid $R/seatd.pid $R/current $R/type $R/wayland
    return 0
}

case "$1" in
    list) list ;;
    check) check ;;
    start) start "$2" ;;
    current) current ;;
    resize) resize ;;
    stop) stop ;;
    running) running ;;
    *) echo "usage: desktop.sh list|check|start [ID]|current|resize|stop|running"; exit 2 ;;
esac

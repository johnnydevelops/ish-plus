# The Desktop session: Xorg on the VM's display (virtio-gpu), with the
# virtio tablet and keyboard iSH+ sends touches and keys to, and the
# desktop environment or window manager the user installed. iSH+ runs it as
# root through the exec agent:
#   desktop.sh check            prints the desktop to use (exit 1: none)
#   desktop.sh start            starts Xorg and the desktop (if not running)
#   desktop.sh resize           uses the size iSH+ offers now (xrandr)
#   desktop.sh stop             ends the desktop and Xorg
B=/opt/ishplus/bin/busybox
R=/run/ishplus-desktop
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

# The desktop to start: "<name>\t<command>". Sessions in /usr/share/xsessions
# (desktops first, GNOME last: it needs systemd), then window managers.
desktop() {
    best=""; best_rank=99
    for f in /usr/share/xsessions/*.desktop; do
        [ -e "$f" ] || continue
        cmd=$($B sed -n 's/^Exec=//p' "$f" | $B head -1)
        name=$($B sed -n 's/^Name=//p' "$f" | $B head -1)
        tryexec=$($B sed -n 's/^TryExec=//p' "$f" | $B head -1)
        [ -n "$cmd" ] || continue
        prog=${tryexec:-${cmd%% *}}
        command -v "$prog" >/dev/null 2>&1 || [ -x "$prog" ] || continue
        case "$($B basename "$f" .desktop)" in
            xfce*) rank=1 ;; mate*) rank=2 ;; lxqt*) rank=3 ;; LXDE*|lxde*) rank=4 ;;
            cinnamon*) rank=5 ;; plasma*|kde*) rank=6 ;; *gnome*|*ubuntu*) rank=20 ;;
            *) rank=10 ;;
        esac
        if [ "$rank" -lt "$best_rank" ]; then
            best="$name	$cmd"; best_rank=$rank
        fi
    done
    [ -n "$best" ] && { echo "$best"; return 0; }
    for wm in openbox-session openbox i3 xfwm4 fluxbox icewm-session icewm jwm awesome \
              herbstluftwm fvwm3 fvwm wmaker twm; do
        command -v "$wm" >/dev/null 2>&1 && { printf '%s\t%s\n' "$wm" "$wm"; return 0; }
    done
    return 1
}

check() {
    xorg >/dev/null && xorg_driver drivers modesetting && { xorg_driver input libinput || xorg_driver input evdev; } \
        && d=$(desktop) && echo "$d" | $B cut -f1
}

running() {
    [ -f $R/xorg.pid ] && $B kill -0 "$($B cat $R/xorg.pid)" 2>/dev/null
}

# What udev would record for the display and input devices, which Xorg and
# libinput read (iSH+'s init runs no udev daemon)
udev_db() {
    $B mkdir -p /run/udev/data /run/udev/tags/seat
    for dev in /sys/class/input/event* /sys/class/drm/card[0-9]; do
        [ -e "$dev/dev" ] || continue
        id="c$($B cat "$dev/dev")"
        name=$($B cat "$dev/device/name" 2>/dev/null)
        {
            case "$dev" in
                */input/*)
                    echo "E:ID_INPUT=1"
                    case "$name" in
                        *[Kk]eyboard*) echo "E:ID_INPUT_KEY=1"; echo "E:ID_INPUT_KEYBOARD=1" ;;
                        *) echo "E:ID_INPUT_MOUSE=1" ;;
                    esac ;;
            esac
            echo "G:seat"; echo "Q:seat"
        } > /run/udev/data/$id
        : > /run/udev/tags/seat/$id
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

start() {
    running && return 0
    xorg=$(xorg) || { echo "Xorg is not installed."; return 1; }
    d=$(desktop) || { echo "No desktop or window manager is installed."; return 1; }
    session=$(echo "$d" | $B cut -f2-)
    $B mkdir -p $R
    # The display and input drivers (not loaded at boot, to save memory)
    $B modprobe -q virtio_input; $B modprobe -q evdev; $B modprobe -q virtio-gpu
    i=0; while [ ! -e /dev/dri/card0 ] && [ $i -lt 50 ]; do $B sleep 0.1; i=$((i + 1)); done
    $B sleep 0.5
    udev_db
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
EOF
    # Xorg allows -config only in its own directories, or as root
    setsid "$xorg" :0 vt7 -nolisten tcp -noreset -s 0 -dpms -config $R/xorg.conf \
        -logfile $R/Xorg.log </dev/null >$R/xorg.out 2>&1 &
    echo $! > $R/xorg.pid
    i=0; while [ ! -e /tmp/.X11-unix/X0 ] && [ $i -lt 100 ]; do
        running || { echo "Xorg did not start:"; $B grep "(EE)" $R/Xorg.log | $B tail -5; return 1; }
        $B sleep 0.2; i=$((i + 1))
    done
    # The desktop, as the user, with its own D-Bus session if there is D-Bus
    who=${user:-root}
    uid=$($B id -u "$who"); gid=$($B id -g "$who")
    $B mkdir -p /run/user/$uid && $B chown "$uid:$gid" /run/user/$uid && $B chmod 700 /run/user/$uid
    wrap=""
    command -v dbus-run-session >/dev/null 2>&1 && wrap="dbus-run-session --"
    [ -z "$wrap" ] && command -v dbus-launch >/dev/null 2>&1 && wrap="dbus-launch --exit-with-session"
    cat > $R/session <<EOF
#!/bin/sh
export DISPLAY=:0 XDG_RUNTIME_DIR=/run/user/$uid XDG_SESSION_TYPE=x11
cd
# A background for bare window managers (desktops draw their own)
command -v xsetroot >/dev/null 2>&1 && xsetroot -solid '#2b3a4a'
exec $wrap $session
EOF
    $B chmod 755 $R/session
    if [ "$who" = root ]; then
        setsid sh -lc $R/session </dev/null >$R/session.log 2>&1 &
    else
        setsid su -l "$who" -c $R/session </dev/null >$R/session.log 2>&1 &
    fi
    echo $! > $R/session.pid
    resize
    return 0
}

# virtio-gpu offers iSH+'s size as the preferred mode; without a udev
# daemon Xorg is not told, so set it (needs xrandr)
resize() {
    running || return 1
    command -v xrandr >/dev/null 2>&1 || return 0
    output=$(DISPLAY=:0 xrandr 2>/dev/null | $B awk '/ connected/ { print $1; exit }')
    [ -n "$output" ] && DISPLAY=:0 xrandr --output "$output" --auto >/dev/null 2>&1
    return 0
}

# Every program of the desktop (they have its DISPLAY), then Xorg
desktop_pids() {
    for p in /proc/[0-9]*; do
        [ "${p#/proc/}" = "$$" ] && continue
        { $B tr '\0' '\n' < "$p/environ"; } 2>/dev/null | $B grep -qx 'DISPLAY=:0' && echo "${p#/proc/}"
    done
}

stop() {
    pids=$(desktop_pids)
    [ -n "$pids" ] && $B kill $pids 2>/dev/null
    [ -f $R/xorg.pid ] && $B kill "$($B cat $R/xorg.pid)" 2>/dev/null
    $B sleep 1
    pids=$(desktop_pids)
    [ -n "$pids" ] && $B kill -9 $pids 2>/dev/null
    [ -f $R/xorg.pid ] && $B kill -9 "$($B cat $R/xorg.pid)" 2>/dev/null
    $B rm -f $R/xorg.pid $R/session.pid
    return 0
}

case "$1" in
    check) check ;;
    start) start ;;
    resize) resize ;;
    stop) stop ;;
    running) running ;;
    *) echo "usage: desktop.sh check|start|resize|stop|running"; exit 2 ;;
esac

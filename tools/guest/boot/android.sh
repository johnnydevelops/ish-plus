# android.sh: boots LineageOS 17.1 (Android 10) inside the guest Linux via
# Waydroid/LXC, with SurfaceFlinger routed through iSH+'s virglrenderer +
# ANGLE Metal GPU. Run inside the guest as root, by /opt/ishplus/boot/main.sh
# when the user starts the "Android" desktop session, or by hand.
#
#   android.sh start          install (once) + start Waydroid
#   android.sh stop           stop Waydroid
#   android.sh status         is Android running?
#   android.sh install        run only the install step
#
# Memory budget on an Apple A13 device (3 GB / 4 GB):
#   * The Linux VM gets 1.4–1.7 GB (MeloNX RAM-donor, outside iSH+'s
#     own footprint). See app/VMSettings.swift.
#   * zram (lz4) covers ~half of that as compressed swap.
#   * Android's lmkd is tuned (build.prop overrides) to free pages before
#     the host's RSS grows enough to trip iOS jetsam.
#   * Waydroid is started without --fullscreen and with a single EGL context
#     per surface (one SurfaceFlinger layer) to keep the GPU buffer count low.
#
# SurfaceFlinger -> Wayland/virglrenderer bridge:
#   Waydroid uses libhybris' hwcomposer to compose to a Wayland surface.
#   iSH+'s wlroots (sway/labwc/weston) compositor talks EGL to virglrenderer
#   via Mesa's gbm + virgl driver, which routes to ANGLE (Metal). Android's
#   gralloc=gbm and egl=mesa props (set by install-waydroid.sh and re-asserted
#   here) make SurfaceFlinger request a gbm_surface, which Waydroid's
#   hwcomposer then blits to the host Wayland surface. There is no SwiftShader
#   in the path: every GL call hits the Metal GPU.
B=/opt/ishplus/bin/busybox
R=/run/ishplus-android
W=/var/lib/waydroid
IMG="$W/images"
mkdir -p "$R"

say()  { echo "ishplus-android: $*"; }
fail() { say "$*"; exit 1; }

# The Wayland display iSH+'s Desktop session exposes (desktop.sh writes it).
# When Android is started by hand without a desktop running, fall back to
# WAYLAND_DISPLAY from the environment or wayland-0.
wayland_display() {
    if [ -n "${WAYLAND_DISPLAY:-}" ]; then echo "$WAYLAND_DISPLAY"; return; fi
    local d=/run/ishplus-desktop/wayland
    [ -r "$d" ] && { cat "$d"; return; }
    echo wayland-0
}

# Re-apply the GPU prop overrides on every start: Waydroid's first boot may
# reset them, and they are what makes Android use the Metal path.
apply_props() {
    [ -d "$W/overlay/system/system" ] || return 0
    cat > "$W/overlay/system/system/build.prop" <<'EOF'
# iSH+ LineageOS 17.1 / Android 10 GPU + memory overrides (android.sh)
ro.hardware.gralloc=gbm
ro.hardware.egl=mesa
ro.hardware.vulkan=moltenvk
ro.hardware.opengles.version=196609
ro.lmk.critical=15
ro.lmk.low=80
ro.lmk.medium=100
ro.lmk.critical_upgrade=false
ro.lmk.upgrade_pressure=40
ro.lmk.downgrade_pressure=60
ro.lmk.kill_heaviest_task=true
dalvik.vm.heapsize=256m
dalvik.vm.heapgrowthlimit=128m
dalvik.vm.heapstartsize=8m
dalvik.vm.heaptargetutilization=0.75
dalvik.vm.heapminfree=512k
ro.com.google.gms=0
debug.sf.latch_unsignaled=1
debug.sf.early_phase_offset_ns=500000
EOF
}

# Binderfs is required for binder IPC. Mounted once; survives stops.
mount_binderfs() {
    [ -d /dev/binderfs ] && return 0
    $B modprobe -q binderfs 2>/dev/null || $B modprobe -q binder_linux 2>/dev/null || \
        fail "binderfs module missing: rebuild guest kernel with CONFIG_ANDROID_BINDERFS"
    mkdir -p /dev/binderfs
    mount -t binder binder /dev/binderfs 2>/dev/null || \
        fail "cannot mount binderfs"
}

# The LXC bridge waydroid0 (10.0.0.0/24). On iSH+'s single-eth0 guest we use
# masquerade (no dnsmasq) so Android sees a real uplink with no DHCP cost.
up_network() {
    if ip link show waydroid0 >/dev/null 2>&1; then return 0; fi
    ip link add waydroid0 type bridge
    ip addr add 10.0.0.1/24 dev waydroid0
    ip link set waydroid0 up
    # Masquerade Android's 10.0.0.0/24 onto the guest's eth0
    iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o eth0 -j MASQUERADE 2>/dev/null || true
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
}

down_network() {
    iptables -t nat -D POSTROUTING -s 10.0.0.0/24 -o eth0 -j MASQUERADE 2>/dev/null || true
    ip link set waydroid0 down 2>/dev/null || true
    ip link del waydroid0 2>/dev/null || true
}

# zram: half the VM's RAM, lz4. swap.sh already does this for the host; this
# is the same call but tightened for the Android workload (lower swappiness
# so lmkd kills first). Re-applied each start so a stop/start cycle restores
# the buffer Android consumed.
tune_zram_for_android() {
    [ -e /sys/block/zram0/disksize ] || return 0
    # zram already set up by swap.sh; just tighten reclaim policy.
    echo 60 > /proc/sys/vm/swappiness 2>/dev/null || true
    # Drop caches before Android starts so its working set isn't competing
    # with the Linux page cache. 3 = pagecache + dentries + inodes.
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
}

install_waydroid() {
    [ -x /usr/bin/waydroid ] || [ -x /usr/local/bin/waydroid ] && return 0
    [ -x /opt/ishplus/waydroid/install-waydroid.sh ] || \
        fail "install-waydroid.sh missing from the support disk"
    /bin/sh /opt/ishplus/waydroid/install-waydroid.sh
}

start_session() {
    [ -x /usr/bin/waydroid ] || [ -x /usr/local/bin/waydroid ] || install_waydroid
    mount_binderfs
    up_network
    apply_props
    tune_zram_for_android
    WAYLAND_DISPLAY=$(wayland_display)
    export WAYLAND_DISPLAY XDG_RUNTIME_DIR=/run/user/0
    mkdir -p "$XDG_RUNTIME_DIR"

    # The Waydroid session: connects to the Wayland compositor and creates
    # the Android surface. Runs as root (LXC needs CAP_SYS_ADMIN).
    waydroid session start >"$R/session.log" 2>&1 &
    echo $! > "$R/session.pid"

    # The LXC container: boots the LineageOS 17.1 root (system.img + vendor.img
    # from /var/lib/waydroid/images). lxc-start keeps it in the foreground;
    # we background it so this script returns. waydroid container start is a
    # thin wrapper around lxc-start.
    waydroid container start >"$R/container.log" 2>&1 &
    echo $! > "$R/container.pid"

    # Wait for the Android surface to appear (Waydroid sets a property when
    # SurfaceFlinger is up). ~10s on A13. On success, drop the "ready" file
    # the kiosk launcher (waydroid-kiosk.sh) waits for.
    i=0
    while [ $i -lt 50 ]; do
        if waydroid status >/dev/null 2>&1; then
            echo ready > "$R/ready"
            return 0
        fi
        sleep 0.2; i=$((i + 1))
    done
    say "Waydroid did not come up in 10 s; see $R/session.log"
    return 1
}

stop_session() {
    [ -f "$R/container.pid" ] && kill "$($B cat "$R/container.pid")" 2>/dev/null || true
    [ -f "$R/session.pid" ]   && kill "$($B cat "$R/session.pid")"   2>/dev/null || true
    waydroid session stop 2>/dev/null || true
    waydroid container stop 2>/dev/null || true
    sleep 1
    rm -f "$R/session.pid" "$R/container.pid" "$R/ready"
    down_network
}

status() {
    waydroid status 2>/dev/null && echo running || echo stopped
}

case "${1:-}" in
    start)   start_session ;;
    stop)    stop_session ;;
    status)  status ;;
    install) install_waydroid ;;
    *) echo "usage: android.sh start|stop|status|install"; exit 2 ;;
esac

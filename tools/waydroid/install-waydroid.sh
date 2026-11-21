#!/bin/sh
# install-waydroid.sh: installs Waydroid + LXC in the guest and registers
# the LineageOS 17.1 image-set. Run inside the guest (Debian/Alpine/etc)
# by /opt/ishplus/boot/android.sh on first start of the Android session.
#
# Two code paths, picked by what the host distribution is:
#   * Debian/Ubuntu (apt)        : waydroid + lxc from the distro repo
#   * Alpine (apk)               : waydroid from community + lxc
#
# Network: NAT, bridge waydroid0 (LXC's default). On a phone without
# network-manager, the bridge is brought up by the init script android.sh.
set -eu

distro() {
    if command -v apt-get >/dev/null 2>&1; then echo apt
    elif command -v apk >/dev/null 2>&1; then echo apk
    elif command -v dnf >/dev/null 2>&1; then echo dnf
    else echo unknown; fi
}

D=$(distro)
case "$D" in
    apt)
        # Waydroid's official APT repo (gives the latest 1.4.x with the
        # Android 10 image-set we ship). Falls back to Debian's waydroid.
        if ! command -v waydroid >/dev/null 2>&1; then
            curl -fsSL https://repo.waydro.id | sudo bash || true
            sudo apt-get update -y
            sudo apt-get install -y --no-install-recommends \
                waydroid lxc iptables dnsmasq cage weston
        else
            # Already installed: make sure the kiosk compositor is too, so the
            # "Android (Waydroid)" session can launch fullscreen.
            sudo apt-get install -y --no-install-recommends cage weston 2>/dev/null || true
        fi
        ;;
    apk)
        sudo apk add --no-cache waydroid lxc iptables dnsmasq cage weston || {
            # Waydroid is in Alpine's community repo; on edge sometimes newer.
            sudo apk add --no-cache -X https://dl-cdn.alpinelinux.org/alpine/edge/community \
                waydroid lxc iptables dnsmasq cage weston
        }
        ;;
    dnf)
        sudo dnf install -y waydroid lxc iptables dnsmasq cage weston
        ;;
    *)
        echo "install-waydroid: unsupported distribution (no apt/apk/dnf)" >&2
        exit 1
        ;;
esac

# The image-set from tools/waydroid/fetch-lineagos-17.sh, copied to the
# guest by iSH+'s support disk (or fetched on first run if missing).
IMGDIR=/var/lib/waydroid/images
sudo mkdir -p "$IMGDIR"
if [ ! -s "$IMGDIR/system.img" ]; then
    if [ -f /opt/ishplus/android/system.img ]; then
        sudo cp /opt/ishplus/android/system.img "$IMGDIR/system.img"
    else
        # Pull the LineageOS 17.1 vanilla image-set directly
        curl -fL --retry 3 -o "$IMGDIR/system.img" \
            "https://sourceforge.net/projects/waydroid/files/images/system/lineage/lineage-17.1-20241220-VANILLA-arm64/system.img/download"
    fi
fi
if [ ! -s "$IMGDIR/vendor.img" ]; then
    if [ -f /opt/ishplus/android/vendor.img ]; then
        sudo cp /opt/ishplus/android/vendor.img "$IMGDIR/vendor.img"
    else
        curl -fL --retry 3 -o "$IMGDIR/vendor.img" \
            "https://sourceforge.net/projects/waydroid/files/images/vendor/lineage/lineage-17.1-20241220-VANILLA-arm64/vendor.img/download"
    fi
fi

# Apply the iSH+-specific prop overrides that wire Android's graphics
# stack into iSH+'s virglrenderer + ANGLE Metal GPU pipeline. These are
# also written by android.sh on every boot, so re-running install-waydroid
# is safe.
PROPDIR=/var/lib/waydroid/overlay
sudo mkdir -p "$PROPDIR/system/system"
sudo tee "$PROPDIR/system/system/build.prop" >/dev/null <<'EOF'
# iSH+ LineageOS 17.1 / Android 10 overrides (written by install-waydroid.sh)
# Hardware gralloc/EGL: gbm + mesa — the path that turns SurfaceFlinger's
# GL output into dma-buf fds virglrenderer consumes. Android's default
# SwiftShader path is replaced.
ro.hardware.gralloc=gbm
ro.hardware.egl=mesa
ro.hardware.vulkan=moltenvk
# OpenGL ES 3.1 — virglrenderer exposes this through ANGLE/Metal on A13.
ro.hardware.opengles.version=196609
# Memory: 3-4 GB A13 device. lmkd kills processes before jetsam notices.
ro.lmk.critical=15
ro.lmk.low=80
ro.lmk.medium=100
ro.lmk.critical_upgrade=false
ro.lmk.upgrade_pressure=40
ro.lmk.downgrade_pressure=60
ro.lmk.kill_heaviest_task=true
# Heap sizes picked for a 1.5 GB RAM slice. Conservative: keeps ART from
# reclaiming the entire RAM and triggering iOS jetsam.
dalvik.vm.heapsize=256m
dalvik.vm.heapgrowthlimit=128m
dalvik.vm.heapstartsize=8m
dalvik.vm.heaptargetutilization=0.75
dalvik.vm.heapminfree=512k
# No GApps (vanilla LineageOS 17.1).
ro.com.google.gms=0
# Render to virtio-gpu's host window directly.
debug.sf.latch_unsignaled=1
debug.sf.early_phase_offset_ns=500000
EOF

# Waydroid needs an LXC bridge on waydroid0 (10.0.0.0/24 by default). On a
# single-user container we don't need a separate subnet; Android shares
# the guest's eth0 over the bridge with masquerade.
sudo mkdir -p /etc/waydroid
sudo tee /etc/waydroid/network.cfg >/dev/null <<'EOF'
# Network is shared with the host guest's eth0; iptables masquerades
# (no separate DHCP/DNS daemon to save memory).
network_backend=masq
network_interfaces=eth0
EOF

# Mount binderfs at /dev/binderfs if it isn't already (the kernel module is
# shipped in ish-plus's modloop — see tools/make-guest-kernel-16k.sh).
if [ ! -d /dev/binderfs ]; then
    sudo mkdir -p /dev/binderfs
    sudo modprobe binderfs 2>/dev/null || sudo modprobe binder_linux 2>/dev/null || true
    sudo mount -t binder binder /dev/binderfs 2>/dev/null || true
fi

# Initialise Waydroid's container definition. The image-set is registered
# without a network (will be brought up by android.sh).
sudo waydroid init -f -i "$IMGDIR/system.img" -v "$IMGDIR/vendor.img" --no-network 2>&1 || true

# Register an Android session entry in the Wayland sessions list, so iSH+'s
# iOS Sessions picker (app/DesktopViewController.swift -> desktop.sh
# sessions()) shows "Android (Waydroid)" as a top-level choice. Picking it
# runs waydroid-kiosk.sh, which:
#   1. /opt/ishplus/boot/android.sh start    (binderfs, bridge, props, container)
#   2. launches cage (or weston kiosk, if cage is absent) as a fullscreen
#      Wayland compositor whose only toplevel is Waydroid's surface.
# SurfaceFlinger then composes straight onto the Metal-backed scanout, with
# no other desktop chrome in the way — Android fills the iPad screen.
sudo install -d /usr/share/wayland-sessions
sudo tee /usr/share/wayland-sessions/waydroid-android.desktop >/dev/null <<'EOF'
[Desktop Entry]
Type=Application
Name=Android (Waydroid)
Comment=LineageOS 17.1 (Android 10) via Waydroid, fullscreen on the Metal GPU
Exec=/opt/ishplus/boot/waydroid-kiosk.sh
Icon=waydroid
DesktopNames=Android
EOF

# The kiosk wrapper. desktop.sh runs this via the session Exec= line. It is
# deliberately minimal: cage (a wlroots-based kiosk compositor ~80 KB) is the
# first choice; weston's kiosk mode is the fallback. Either pins Waydroid's
# surface to the full screen and routes input, then exits when Android stops.
sudo install -d /opt/ishplus/boot
sudo tee /opt/ishplus/boot/waydroid-kiosk.sh >/dev/null <<'EOF'
#!/bin/sh
# waydroid-kiosk.sh: boots Android and shows it fullscreen, no desktop chrome.
# Invoked by desktop.sh when the user picks the "Android (Waydroid)" session.
set -eu
B=/opt/ishplus/bin/busybox

# 1. Start the container + session (idempotent; safe if already running).
/opt/ishplus/boot/android.sh start || {
    echo "waydroid-kiosk: Android did not start; check /run/ishplus-android/session.log" >&2
    exit 1
}

# 2. Wait for Waydroid's surface to exist (Waydroid writes /run/ishplus-android/ready
#    once its hwcomposer has registered the toplevel; android.sh writes it).
i=0
while [ $i -lt 100 ] && [ ! -r /run/ishplus-android/ready ]; do
    $B sleep 0.1; i=$((i + 1))
done

# 3. Pick a compositor: cage (preferred kiosk) else weston (kiosk shell).
WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export WAYLAND_DISPLAY XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/0}"
export WAYDROID_DISPLAY=wayland-0

# cage: a single-output, single-surface wlroots compositor. Each child added
# with -d is shown fullscreen on its output. We hand it Waydroid.
if command -v cage >/dev/null 2>&1; then
    # cage's output is the host surface QEMU scans out into Metal; Android
    # fills it because cage makes every toplevel fullscreen.
    exec cage -d -- \
        /bin/sh -c 'waydroid show-full-ui >/dev/null 2>&1; exec sleep infinity'
fi

# weston fallback: kiosk shell, single surface fullscreen.
if command -v weston >/dev/null 2>&1; then
    mkdir -p /tmp/ishplus-weston
    cat > /tmp/ishplus-weston.ini <<'INI'
[core]
shell=kiosk
[xwayland]
[output]
name=wayland-0
[app-launchers]
launcher=/usr/bin/waydroid
INI
    exec weston --shell=kiosk \
        --xwayland \
        --config=/tmp/ishplus-weston.ini \
        --idle-time=0
fi

echo "waydroid-kiosk: neither cage nor weston is installed; install one with:" >&2
echo "  apt-get install cage   # or: apk add cage" >&2
exit 1
EOF
sudo chmod 755 /opt/ishplus/boot/waydroid-kiosk.sh

echo "Waydroid installed. Start Android with one of:"
echo "  * The iOS Sessions picker -> \"Android (Waydroid)\""
echo "  * /opt/ishplus/boot/waydroid-kiosk.sh        (fullscreen)"
echo "  * /opt/ishplus/boot/android.sh start        (in a window)"

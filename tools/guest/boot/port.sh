# Sourced: port NAME prints the device of the virtio-serial port iSH+ named
# NAME (there is no udev to make /dev/virtio-ports links).
port() {
    for d in /sys/class/virtio-ports/*; do
        [ "$(/opt/ishplus/bin/busybox cat "$d/name" 2>/dev/null)" = "$1" ] && { echo "/dev/${d##*/}"; return 0; }
    done
    return 1
}

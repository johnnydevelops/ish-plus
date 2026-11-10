# Before iSH+ saves the VM (when it goes to the background): write
# everything to disk, drop the file cache (Linux reports the memory freed,
# which goes back to iOS, and the saved state is smaller), and unmount the
# iOS share (QEMU cannot save a VM while a 9p share is mounted). Prints
# "ready" when the VM can be saved.
B=/opt/ishplus/bin/busybox
$B sync
echo 3 > /proc/sys/vm/drop_caches
if $B mountpoint -q /mnt/ios; then
    $B umount /mnt/ios 2>/dev/null || $B umount -l /mnt/ios
fi
$B sync
$B mountpoint -q /mnt/ios || echo ready

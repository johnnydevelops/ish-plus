# Before iSH+ saves the VM: write everything to disk, and unmount the iOS
# share (QEMU cannot save a VM while a 9p share is mounted). Prints "ready"
# when the VM can be saved.
B=/opt/ishplus/bin/busybox
$B sync
if $B mountpoint -q /mnt/ios; then
    $B umount /mnt/ios 2>/dev/null || $B umount -l /mnt/ios
fi
$B sync
$B mountpoint -q /mnt/ios || echo ready

# After iSH+ restored or continued the VM: the time (the guest's clock
# stopped while it was saved; $1 is the time now, in seconds since 1970),
# and the iOS share again.
B=/opt/ishplus/bin/busybox
[ -n "$1" ] && $B date -s "@$1" >/dev/null
$B mountpoint -q /mnt/ios || $B mount -t 9p -o trans=virtio,version=9p2000.L,msize=1048576,cache=mmap ishplus-share /mnt/ios

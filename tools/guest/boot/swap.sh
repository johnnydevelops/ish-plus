# Swap for Linux (run by main.sh): compressed swap in Linux's own RAM
# (zram), half of it in size. Under memory pressure, idle pages are
# compressed (typically 2-3x) instead of programs being killed. Not a swap
# file: that would take the iPad's storage and wear its flash. Skipped when
# the distribution already set up swap (e.g. Fedora's zram-generator).
B=/opt/ishplus/bin/busybox
[ -n "$($B tail -n +2 /proc/swaps)" ] && exit 0
$B modprobe -q zram num_devices=1 2>/dev/null
Z=/sys/block/zram0
[ -e $Z/disksize ] || exit 0
# Never set up twice (main.sh runs again if its service restarts)
[ "$($B cat $Z/disksize)" = 0 ] || exit 0
# lz4: the fastest to compress, which matters under emulation
for algorithm in lz4 lzo-rle lzo zstd; do
    if $B grep -qw "$algorithm" $Z/comp_algorithm; then
        echo $algorithm > $Z/comp_algorithm 2>/dev/null && break
    fi
done
kb=$($B awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
echo $((kb / 2))K > $Z/disksize || exit 0
$B mkswap /dev/zram0 >/dev/null 2>&1 && $B swapon -p 100 /dev/zram0 2>/dev/null || exit 0
# Swapping to RAM is cheap next to dropping file pages read back from disk
echo 100 > /proc/sys/vm/swappiness

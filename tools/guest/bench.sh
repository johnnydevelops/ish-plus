echo "=== ISHPLUS BENCH START"
echo "uptime_at_autorun $(cut -d' ' -f1 /proc/uptime)"
echo "cpus $(grep -c ^processor /proc/cpuinfo)"
now() { tr -d . < /proc/uptime | cut -d' ' -f1; }
t() { n=$1; shift; s=$(now); "$@" >/dev/null 2>&1; e=$(now); echo "bench $n $(( (e - s) * 10 )) ms"; }
loop() { i=0; while [ $i -lt 300000 ]; do i=$((i+1)); done; }
par() { for j in 1 2 3 4; do (dd if=/dev/zero bs=1M count=64 | md5sum) & done; wait; }
t shell_loop loop
t md5_128M sh -c 'dd if=/dev/zero bs=1M count=128 | md5sum'
t gzip_64M sh -c 'dd if=/dev/zero bs=1M count=64 | gzip -1 > /dev/null'
t exec_300 sh -c 'for i in $(seq 1 300); do /bin/true; done'
t find_root sh -c 'find / -xdev > /dev/null'
t md5_4par par
echo "=== ISHPLUS BENCH END"

echo "=== ISHPLUS BENCH START"
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
echo "binfmt: $(cat /proc/sys/fs/binfmt_misc/FEX-x86_64 2>&1 | head -1)"
echo "x86 root: $(cat /opt/x86_64/etc/alpine-release 2>&1)"
echo "x86 uname: $(/opt/x86_64/bin/busybox uname -m 2>&1)"
echo "x86 cmd: $(x86 busybox echo hello-from-x86 2>&1)"
now() { tr -d . < /proc/uptime | cut -d' ' -f1; }
s=$(now); /opt/x86_64/bin/busybox sh -c 'i=0; while [ $i -lt 100000 ]; do i=$((i+1)); done'; e=$(now); echo "x86 shell_loop_100k $(( (e-s)*10 )) ms"
s=$(now); sh -c 'i=0; while [ $i -lt 100000 ]; do i=$((i+1)); done'; e=$(now); echo "arm shell_loop_100k $(( (e-s)*10 )) ms"
apk-x86 add -q file 2>&1 | tail -3; echo "apk-x86 done" 2>&1 | tail -3
echo "x86 file: $(x86 file /bin/busybox 2>&1)"
echo "=== ISHPLUS BENCH END"

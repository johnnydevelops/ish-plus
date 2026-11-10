# A root login shell for one iSH+ session, like iSH's.
B=/opt/ishplus/bin/busybox
shell=$($B awk -F: '$1 == "root" { print $7 }' /etc/passwd 2>/dev/null)
[ -x "$shell" ] || shell=/bin/sh
[ -x "$shell" ] || shell="$B sh"
export HOME=/root USER=root LOGNAME=root SHELL="$shell" TERM=xterm-256color LANG=C.UTF-8
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$B stty sane 2>/dev/null
cd "$HOME" 2>/dev/null || cd /
# The welcome message, as login prints it
[ -s /etc/motd ] && $B cat /etc/motd
exec $shell -l

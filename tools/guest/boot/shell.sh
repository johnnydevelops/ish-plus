# A login shell for one iSH+ session: as the user chosen when the
# distribution was added, or root (like iSH) for distributions without one.
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
# The user chosen when the distribution was added, if any
user=$($B cat /etc/ishplus/user 2>/dev/null)
if [ -n "$user" ] && $B grep -q "^$user:" /etc/passwd; then
    cd /
    su=$(command -v su || echo "$B su")
    exec $su -l "$user"
fi
exec $shell -l

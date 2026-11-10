# Hangs up the processes on console $1 (/dev/hvc$1), when iSH+ closes the
# session on it, as closing a terminal window does: the console's next
# session starts with a new shell.
B=/opt/ishplus/bin/busybox
dev=/dev/hvc$1
[ -e "$dev" ] || exit 0
# The console's device number, as /proc/*/stat's tty_nr
tty=$(( (0x$($B stat -c %t "$dev") << 8) | 0x$($B stat -c %T "$dev") ))
for stat in /proc/[0-9]*/stat; do
    # Fields after the command name: state ppid pgrp session tty_nr
    fields=$($B sed 's/.*) //' "$stat" 2>/dev/null) || continue
    set -- $fields
    pid=${stat%/stat}; pid=${pid#/proc/}
    [ "$5" = "$tty" ] && kill -HUP "$pid" 2>/dev/null
done
exit 0

# Runs commands sent by iSH+ (the Run Command shortcut) and returns their
# output. Requests: "<id> <length>\n<command>"; replies:
# "<id> <status> <length>\n<output>". One at a time, as the user sessions
# log in as (or root).
B=/opt/ishplus/bin/busybox
. /opt/ishplus/boot/port.sh
while ! P=$(port org.ishplus.exec); do $B sleep 5; done
out=/run/ishplus-exec.out
while :; do
    exec 3<>"$P" || { $B sleep 5; continue; }
    while read -r id length <&3; do
        command=$($B head -c "$length" <&3)
        user=$($B cat /etc/ishplus/user 2>/dev/null)
        if [ -n "$user" ] && $B grep -q "^$user:" /etc/passwd; then
            su -l "$user" -c "$command" </dev/null >"$out" 2>&1
        else
            (cd /root && HOME=/root sh -lc "$command") </dev/null >"$out" 2>&1
        fi
        status=$?
        printf '%s %s %s\n' "$id" "$status" "$($B wc -c < "$out")" >&3
        $B cat "$out" >&3
    done
    exec 3>&-
    $B sleep 1
done

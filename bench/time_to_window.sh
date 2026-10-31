#!/bin/sh
# Time to window: runs a terminal and returns as soon as it has a NEW
# window on screen (one whose class matches CLASS). For hyperfine, it
# times "command started -> window mapped", the same thing for any
# terminal, whether it keeps running (alacritty, ghostty) or hands off to
# a background process and exits (guiltty's launcher). Needs wmctrl and a
# window manager; run it from another terminal, with guiltty stopped.
#
#   bench/time_to_window.sh CLASS COMMAND [ARGS...]
#
# The new window's id goes to $TTW_ID_FILE (default /tmp/ttw.id), for
# close_window.sh in hyperfine's --conclude. See book chapter 22.
class=$1
shift
ids() { wmctrl -lx | awk -v c="$class" 'tolower($3) ~ tolower(c) { print $1 }'; }

before=$(ids)
"$@" >/dev/null 2>&1 &

# Give up after 20 s (4000 polls of 5 ms): a command that never shows a
# window (a typo, a missing program) fails instead of hanging hyperfine.
tries=0
while [ "$tries" -lt 4000 ]; do
    for id in $(ids); do
        case " $before " in
        *" $id "*) ;;
        *) echo "$id" >"${TTW_ID_FILE:-/tmp/ttw.id}"; exit 0 ;;
        esac
    done
    tries=$((tries + 1))
    sleep 0.005
done
echo "time_to_window: no new '$class' window after 20 s from: $*" >&2
exit 1

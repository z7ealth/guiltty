#!/bin/sh
# Closes the window time_to_window.sh found, as if you clicked its close
# button (_NET_CLOSE_WINDOW), then waits until it's gone, so the next run
# starts from the same state.
#
#   bench/close_window.sh            for alacritty, ghostty...
#   bench/close_window.sh guiltty    also waits for guiltty's background node
#                                    to stop, so every run is a cold start
id=$(cat "${TTW_ID_FILE:-/tmp/ttw.id}") || exit 0
wmctrl -ic "$id"
while wmctrl -l | grep -q "^$id "; do sleep 0.02; done
if [ "$1" = guiltty ]; then
    node=${GUILTTY_BIN:-$HOME/.local/lib/guiltty/bin/guiltty}
    while "$node" pid >/dev/null 2>&1; do sleep 0.1; done
fi
exit 0

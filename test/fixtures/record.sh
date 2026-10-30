#!/usr/bin/env bash
# Records a real program's output as a byte fixture for the golden tests.
#
#   test/fixtures/record.sh NAME 'COMMAND' [KEY...]
#
# Runs COMMAND with script(1) (util-linux) in an 80x24 xterm-256color PTY,
# and saves exactly the bytes it wrote to test/fixtures/NAME.bytes. Each KEY
# is typed after a short pause, for interactive programs like less: e.g.
#
#   test/fixtures/record.sh less_page 'less /etc/services' ' ' ' ' b q
#
# Then run `GUILTTY_UPDATE_GOLDEN=1 mix test test/guiltty/golden_test.exs`
# to write NAME.txt, and check it against what a real terminal shows.
set -euo pipefail

name=$1
command=$2
shift 2
dir=$(cd "$(dirname "$0")" && pwd)
raw=$(mktemp)
trap 'rm -f "$raw"' EXIT

# Type each key after a pause, so the program has drawn and switched its
# terminal to raw mode first (otherwise the kernel would echo the key, or
# the program would flush it). RECORD_DELAY sets the first pause.
type_keys() {
    sleep "${RECORD_DELAY:-2}"
    for key in "$@"; do
        printf '%s' "$key"
        sleep 0.5
    done
    sleep 1
}

# UTF-8, like a real session. (Fixtures from before MVP 5 were recorded
# with LC_ALL=C, which kept them ASCII.)
type_keys "$@" |
    SHELL=/bin/bash TERM=xterm-256color LC_ALL=C.UTF-8 COLORTERM=truecolor \
        script --quiet --log-out "$raw" --command "stty cols 80 rows 24; $command" >/dev/null ||
    true # the program's exit status doesn't matter, only its output

# script(1) wraps the output in a "Script started on ..." line and a
# "Script done on ..." line; keep only what the program wrote.
sed -e '1d' -e '$d' "$raw" | head -c -1 >"$dir/$name.bytes"
echo "recorded $(wc -c <"$dir/$name.bytes") bytes to test/fixtures/$name.bytes"

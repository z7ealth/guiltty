#!/usr/bin/env bash
# Installs guiltty for you (no root needed), or updates it:
#
#   ./install.sh               build and install into ~/.local
#   ./install.sh --uninstall   remove it (your ~/.config/guiltty stays)
#   ./install.sh --yes         don't ask before stopping a running guiltty
#   PREFIX=/somewhere ./install.sh
#
# What goes where:
#
#   ~/.local/lib/guiltty/                     the release: guiltty with its own Erlang
#   ~/.local/bin/guiltty                      the command (starts it, or opens a window)
#   ~/.local/share/applications/guiltty.desktop        the menu entry
#   ~/.local/share/icons/hicolor/NxN/apps/guiltty.png  the icon, in each size
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
APP="$PREFIX/lib/guiltty"
BIN="$PREFIX/bin/guiltty"
APPS="$PREFIX/share/applications"
DESKTOP="$APPS/guiltty.desktop"
ICONS="$PREFIX/share/icons/hicolor"
SIZES="16 24 32 48 64 128 256"
here=$(cd "$(dirname "$0")" && pwd)

yes=false
uninstall=false
for arg in "$@"; do
    case "$arg" in
    --yes) yes=true ;;
    --uninstall) uninstall=true ;;
    *) echo "usage: $0 [--uninstall] [--yes]" >&2; exit 2 ;;
    esac
done

# The release answers `pid` only while it runs.
running() { [ -x "$1/bin/guiltty" ] && "$1/bin/guiltty" pid >/dev/null 2>&1; }

# Whether this script runs in one of the installed guiltty's own tabs:
# then guiltty's VM is one of its ancestors (a tab's shell is its child).
inside=false
inside_installed() {
    local vm p=$$
    vm=$("$APP/bin/guiltty" pid 2>/dev/null) || return 1
    while [ -n "$p" ] && [ "$p" -gt 1 ]; do
        [ "$p" = "$vm" ] && return 0
        # The parent pid is the 2nd field after the name, which is in
        # parentheses and may hold spaces (proc_pid_stat(5)).
        p=$(sed 's/.*) //' "/proc/$p/stat" 2>/dev/null | cut -d' ' -f2) || return 1
    done
    return 1
}

LOG="${XDG_STATE_HOME:-$HOME/.local/state}/guiltty/install.log"

# Stop the installed guiltty before replacing or removing it. That closes
# its tabs, so ask first.
stop_installed() {
    running "$APP" || return 0
    inside_installed && inside=true
    if ! $yes; then
        if $inside; then
            read -r -p "guiltty is running, in this very tab too: stopping it closes every tab. Go on? [y/N] " answer
        else
            read -r -p "guiltty is running; stopping it closes its tabs. Go on? [y/N] " answer
        fi
        [ "$answer" = y ] || [ "$answer" = Y ] || { echo "nothing changed"; exit 1; }
    fi

    # From inside guiltty, stopping it closes the terminal this script
    # runs in: the kernel sends SIGHUP, and writing to the closed terminal
    # fails. Ignore the one and write the rest to a log, so the install
    # finishes anyway; guiltty opens again at the end.
    if $inside; then
        mkdir -p "$(dirname "$LOG")"
        echo "this tab closes now; the install goes on (log: $LOG) and guiltty opens again when it's done"
        trap '' HUP
        exec >"$LOG" 2>&1
    fi
    echo "stopping the installed guiltty"
    "$APP/bin/guiltty" stop
}

refresh_desktop() {
    # Menus and icon lookups read these caches; both tools are optional.
    command -v update-desktop-database >/dev/null && update-desktop-database -q "$APPS" || true
    command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -f -t "$ICONS" || true
}

if $uninstall; then
    stop_installed
    rm -rf "$APP" "$BIN" "$DESKTOP"
    for size in $SIZES; do rm -f "$ICONS/${size}x${size}/apps/guiltty.png"; done
    refresh_desktop
    echo "guiltty is uninstalled (your config in ~/.config/guiltty is still there)"
    exit 0
fi

# guiltty's node takes its cookie from ~/.erlang.cookie (book chapter
# 20), and Erlang refuses to start if anyone but you can read that file.
cookie="$HOME/.erlang.cookie"
if [ -e "$cookie" ] && [ -n "$(find "$cookie" -perm /077)" ]; then
    echo "$cookie can be read by other users; guiltty (and Erlang) won't use it." >&2
    echo "Make it yours alone first: chmod 400 $cookie" >&2
    exit 1
fi

# What building needs: Elixir, a C compiler, the renderers' libraries, and
# glslc (from shaderc) to compile the Vulkan shaders.
missing=()
for tool in mix gcc pkg-config make glslc; do command -v "$tool" >/dev/null || missing+=("$tool"); done
for lib in sdl3 freetype2 fontconfig harfbuzz vulkan; do
    pkg-config --exists "$lib" 2>/dev/null || missing+=("$lib (development files)")
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "can't build guiltty, missing: ${missing[*]}" >&2
    echo "the README lists what to install, and why" >&2
    exit 1
fi

# Mix fetches the dependencies with Hex, and telemetry builds with rebar3.
# On a fresh Elixir both are missing, and Mix would stop to ask for them.
(cd "$here" && mix local.hex --force --if-missing >/dev/null && mix local.rebar --force --if-missing >/dev/null)

# Build the release next to the old one, then swap them, so a failed build
# leaves the installed guiltty as it was.
echo "building guiltty (MIX_ENV=prod)..."
rm -rf "$APP.new"
(cd "$here" && MIX_ENV=prod mix deps.get --only prod >/dev/null &&
    MIX_ENV=prod mix release guiltty --overwrite --quiet --path "$APP.new")

# Swapped with two renames, so there's never a moment with no guiltty
# installed: if anything stops the script here, one of the two is in place.
stop_installed
rm -rf "$APP.old"
[ -e "$APP" ] && mv "$APP" "$APP.old"
mv "$APP.new" "$APP"
rm -rf "$APP.old"

# The `guiltty` command is the release's small C client (book chapter 23):
# it asks the running guiltty for a window, or starts guiltty; any other
# argument (stop, remote, pid...) goes to the release's own script. A link,
# so the client finds the release it belongs to.
version=$(cut -d' ' -f2 "$APP/releases/start_erl.data")
mkdir -p "$(dirname "$BIN")"
rm -f "$BIN"
ln -s "$APP/lib/guiltty-$version/priv/guiltty" "$BIN"

for size in $SIZES; do
    install -D -m 644 "$here/priv/icons/guiltty-$size.png" "$ICONS/${size}x${size}/apps/guiltty.png"
done

# StartupWMClass matches the window's class (the renderer sets it to
# "guiltty"), so the taskbar knows the window belongs to this entry.
# No startup notification: the command returns before the window appears.
mkdir -p "$APPS"
cat >"$DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=guiltty
GenericName=Terminal
Comment=A GPU terminal emulator in Elixir and C
Exec=$BIN
Icon=guiltty
Terminal=false
Categories=System;TerminalEmulator;
Keywords=terminal;shell;prompt;command;commandline;
StartupWMClass=guiltty
StartupNotify=false
EOF
command -v desktop-file-validate >/dev/null && desktop-file-validate "$DESKTOP"
refresh_desktop

echo "guiltty $version is installed: run guiltty, or find it in your menu"

# Started from one of its tabs, the update closed every window: open one,
# on the new version, so the update ends where it began.
if $inside; then
    "$BIN" || echo "couldn't start guiltty again: run guiltty"
fi
if running "$here/_build/prod/rel/guiltty"; then
    echo "note: a guiltty from _build/prod is running. Stop it first" \
        "($here/_build/prod/rel/guiltty/bin/guiltty stop): both use the node name guiltty@127.0.0.1."
fi
case ":$PATH:" in
*":$(dirname "$BIN"):"*) ;;
*) echo "note: $(dirname "$BIN") isn't in your PATH; the menu entry works anyway" ;;
esac

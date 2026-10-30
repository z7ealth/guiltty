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

# Stop the installed guiltty before replacing or removing it. That closes
# its tabs, so ask first.
stop_installed() {
    running "$APP" || return 0
    if ! $yes; then
        read -r -p "guiltty is running; stopping it closes its tabs. Go on? [y/N] " answer
        [ "$answer" = y ] || [ "$answer" = Y ] || { echo "nothing changed"; exit 1; }
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

stop_installed
rm -rf "$APP"
mv "$APP.new" "$APP"

mkdir -p "$(dirname "$BIN")"
cat >"$BIN" <<EOF
#!/bin/sh
# Installed by guiltty's install.sh. Starts guiltty if needed and opens a
# window; any other argument (stop, remote, pid...) goes to the release.
exec "$APP/bin/guiltty" "\$@"
EOF
chmod +x "$BIN"

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
Comment=A GPU terminal emulator in Elixir
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

version=$(cut -d' ' -f2 "$APP/releases/start_erl.data")
echo "guiltty $version is installed: run guiltty, or find it in your menu"
if running "$here/_build/prod/rel/guiltty"; then
    echo "note: a guiltty from _build/prod is running. Stop it first" \
        "($here/_build/prod/rel/guiltty/bin/guiltty stop): both use the node name guiltty."
fi
case ":$PATH:" in
*":$(dirname "$BIN"):"*) ;;
*) echo "note: $(dirname "$BIN") isn't in your PATH; the menu entry works anyway" ;;
esac

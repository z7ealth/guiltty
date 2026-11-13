#!/usr/bin/env bash
# Installs guiltty for you (no root needed), or updates it. Three ways:
#
#   curl -fsSL https://raw.githubusercontent.com/z7ealth/guiltty/master/install.sh | bash
#                             downloads the latest precompiled release
#   ./install.sh              in an unpacked release tarball: installs it
#   ./install.sh              in a git checkout: builds from source (needs
#                             Elixir and a C23 compiler; see the README)
#
# Options (after `bash -s --` when piped):
#
#   --yes         install missing libraries and stop a running guiltty
#                 without asking
#   --uninstall   remove it (your ~/.config/guiltty stays)
#
#   GUILTTY_VERSION=v0.26.0   a release other than the latest (download only)
#   PREFIX=/somewhere         where it goes (default ~/.local)
#
# What goes where:
#
#   ~/.local/lib/guiltty/                     the release: guiltty with its own Erlang
#   ~/.local/bin/guiltty                      the command (starts it, or opens a window)
#   ~/.local/share/applications/guiltty.desktop        the menu entry
#   ~/.local/share/icons/hicolor/NxN/apps/guiltty.png  the icon, in each size
#
# Only installing missing libraries uses root (sudo), and only after you
# say yes. Read this file before piping it into a shell: that's what
# it's for. Book chapter 17 explains each step.
set -euo pipefail

REPO="z7ealth/guiltty"
PREFIX="${PREFIX:-$HOME/.local}"
APP="$PREFIX/lib/guiltty"
BIN="$PREFIX/bin/guiltty"
APPS="$PREFIX/share/applications"
DESKTOP="$APPS/guiltty.desktop"
ICONS="$PREFIX/share/icons/hicolor"
SIZES="16 24 32 48 64 128 256"
LOG="${XDG_STATE_HOME:-$HOME/.local/state}/guiltty/install.log"

yes=false
uninstall=false
inside=false

say() { printf '%s\n' "$*"; }
warn() { printf 'guiltty: %s\n' "$*" >&2; }
die() { warn "$*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1; }

# A terminal to talk to. Piped into bash, stdin is this script, so
# questions are read from the terminal itself. /dev/tty can exist and
# still not open (a container, cron, CI: no controlling terminal).
has_tty() { (exec </dev/tty) 2>/dev/null; }

ask() {
    $yes && return 0
    has_tty || die "can't ask (no terminal): run again with --yes"
    local answer
    printf '%s [y/N] ' "$1" >/dev/tty
    read -r answer </dev/tty || return 1
    case "$answer" in y | Y | yes | Yes) return 0 ;; *) return 1 ;; esac
}

# --- Stopping the installed guiltty ---

# The release answers `pid` only while it runs.
running() { [ -x "$1/bin/guiltty" ] && "$1/bin/guiltty" pid >/dev/null 2>&1; }

# Whether this script runs in one of the installed guiltty's own tabs:
# then guiltty's VM is one of its ancestors (a tab's shell is its child).
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

# Stop the installed guiltty before replacing or removing it. That closes
# its tabs, so ask first.
stop_installed() {
    running "$APP" || return 0
    inside_installed && inside=true
    if $inside; then
        ask "guiltty is running, in this very tab too: stopping it closes every tab. Go on?" ||
            die "nothing changed"
    else
        ask "guiltty is running; stopping it closes its tabs. Go on?" || die "nothing changed"
    fi

    # From inside guiltty, stopping it closes the terminal this script
    # runs in: the kernel sends SIGHUP, and writing to the closed terminal
    # fails. Ignore the one and write the rest to a log, so the install
    # finishes anyway; guiltty opens again at the end.
    if $inside; then
        mkdir -p "$(dirname "$LOG")"
        say "this tab closes now; the install goes on (log: $LOG) and guiltty opens again when it's done"
        trap '' HUP
        exec >"$LOG" 2>&1
    fi
    say "stopping the installed guiltty"
    "$APP/bin/guiltty" stop </dev/null
}

refresh_desktop() {
    # Menus and icon lookups read these caches; both tools are optional.
    if need update-desktop-database; then update-desktop-database -q "$APPS" || true; fi
    if need gtk-update-icon-cache; then gtk-update-icon-cache -q -f -t "$ICONS" || true; fi
}

do_uninstall() {
    stop_installed
    rm -rf "$APP" "$BIN" "$DESKTOP"
    for size in $SIZES; do rm -f "$ICONS/${size}x${size}/apps/guiltty.png"; done
    refresh_desktop
    say "guiltty is uninstalled (your config in ~/.config/guiltty is still there)"
}

# --- The distribution, for the package names ---

# Sets `family` (suse, fedora, debian, arch or empty) from os-release(5).
family=""
detect_family() {
    [ -r /etc/os-release ] || return 0
    local id
    # shellcheck disable=SC1091
    for id in $(. /etc/os-release && echo "${ID:-} ${ID_LIKE:-}"); do
        case "$id" in
        opensuse* | suse | sles) family=suse ;;
        fedora | rhel | centos) family=fedora ;;
        debian | ubuntu) family=debian ;;
        arch | archlinux) family=arch ;;
        esac
        [ -n "$family" ] && return 0
    done
}

# The package that holds a library, by soname, on this family. Empty when
# we don't know it.
package_for() {
    case "$family:$1" in
    suse:libfontconfig.so.1 | fedora:libfontconfig.so.1 | arch:libfontconfig.so.1) echo fontconfig ;;
    debian:libfontconfig.so.1) echo libfontconfig1 ;;
    suse:libfreetype.so.6 | debian:libfreetype.so.6) echo libfreetype6 ;;
    fedora:libfreetype.so.6) echo freetype ;;
    arch:libfreetype.so.6) echo freetype2 ;;
    suse:libharfbuzz.so.0) echo libharfbuzz0 ;;
    debian:libharfbuzz.so.0) echo libharfbuzz0b ;;
    fedora:libharfbuzz.so.0 | arch:libharfbuzz.so.0) echo harfbuzz ;;
    suse:libpng16.so.16 | debian:libpng16.so.16) echo libpng16-16 ;;
    fedora:libpng16.so.16 | arch:libpng16.so.16) echo libpng ;;
    suse:libvulkan.so.1 | debian:libvulkan.so.1) echo libvulkan1 ;;
    fedora:libvulkan.so.1) echo vulkan-loader ;;
    arch:libvulkan.so.1) echo vulkan-icd-loader ;;
    suse:libz.so.1) echo libz1 ;;
    debian:libz.so.1) echo zlib1g ;;
    fedora:libz.so.1) echo zlib-ng-compat ;;
    arch:libz.so.1) echo zlib ;;
    suse:libstdc++.so.6) echo libstdc++6 ;;
    debian:libstdc++.so.6) echo libstdc++6 ;;
    fedora:libstdc++.so.6) echo libstdc++ ;;
    arch:libstdc++.so.6) echo gcc-libs ;;
    esac
}

install_packages() {
    local cmd sudo=""
    [ "$(id -u)" -eq 0 ] || sudo="sudo "
    case "$family" in
    suse) cmd="${sudo}zypper install" ;;
    fedora) cmd="${sudo}dnf install" ;;
    debian) cmd="${sudo}apt update && ${sudo}apt install" ;;
    # -Syu, not -S: Arch supports only whole-system upgrades. Installing
    # from a fresh package list onto an old system pulls in libraries
    # newer than what's installed (a "partial upgrade") and breaks it.
    arch) cmd="${sudo}pacman -Syu --needed" ;;
    esac
    # With --yes, the package manager doesn't ask either; without it, it
    # asks its own question too, listing what else it pulls in.
    if $yes; then
        case "$family" in arch) cmd="$cmd --noconfirm" ;; *) cmd="$cmd -y" ;; esac
    fi
    cmd="$cmd $*"
    say "  $cmd"
    ask "Install them now?" || die "not installed; run the command above yourself, then this script again"
    if has_tty; then sh -c "$cmd" </dev/tty; else sh -c "$cmd" </dev/null; fi
}

# --- A precompiled release: the libraries it needs from the system ---
#
# The tarball carries guiltty, its Erlang and SDL3. What it takes from
# the system is listed in dist/build.sh: the C library (glibc 2.36 or
# newer: it was built on Debian 12), the C++ runtime, zlib, and the
# desktop's font and image libraries. ld.so(8) says which are missing
# (ldd prints "not found"). Vulkan is optional: without it the
# window falls back to OpenGL (book chapter 19).
check_runtime_libs() {
    local release=$1 priv f lib arrow rest out pkg line glibc="" have
    local -a required=() optional=() packages=()
    need ldd || die "ldd is needed (it comes with the C library)"
    priv=$(echo "$release"/lib/guiltty-*/priv)
    # Every program and library of guiltty's own, and the VM. The NIFs
    # matter as much as the renderers: they're loaded into the VM later,
    # when a tab opens, and fail there if they can't be.
    for f in "$priv/guiltty_vk" "$priv/guiltty_gl" "$priv/guiltty" "$priv"/*.so \
        "$release"/erts-*/bin/beam.smp; do
        # A missing library reads "libfoo.so.1 => not found"; a C library
        # too old for us, "version `GLIBC_2.36' not found". Plain bash, no
        # awk: a minimal system may not have it, and a check that can't
        # run must not pass.
        out=$(ldd "$f" 2>&1) || die "can't check $f with ldd"
        while read -r line; do
            case "$line" in
            *"version \`GLIBC_"*"' not found"*)
                # The newest one asked for is the one to report.
                line=${line#*\`GLIBC_}
                line=${line%%\'*}
                if [ -z "$glibc" ] || [ "$(printf '%s\n%s\n' "$glibc" "$line" | sort -V | tail -n 1)" = "$line" ]; then
                    glibc=$line
                fi
                ;;
            esac
            read -r lib arrow rest <<<"$line"
            [ "$arrow $rest" = "=> not found" ] || continue
            case "$lib" in
            libvulkan.so.1) optional+=("$lib") ;;
            *) required+=("$lib") ;;
            esac
        done <<<"$out"
    done

    # glibc is the one library a package manager can't bring up to date:
    # it's the distribution's own, so the answer is a newer distribution
    # (or building from source, which links against what's there).
    if [ -n "$glibc" ]; then
        # getconf(1) asks glibc itself ("glibc 2.35"): no pipe to break.
        have=$(getconf GNU_LIBC_VERSION 2>/dev/null) || have="an older one"
        have=${have#glibc }
        warn "this guiltty needs glibc $glibc or newer, and this system has $have."
        warn "That's Ubuntu 23.04, Debian 12, or any current Fedora, Arch or openSUSE;"
        die "on an older system, build from source instead (README, \"Build from source\")"
    fi

    # Each library once.
    mapfile -t required < <(printf '%s\n' "${required[@]}" | sed '/^$/d' | sort -u)
    mapfile -t optional < <(printf '%s\n' "${optional[@]}" | sed '/^$/d' | sort -u)

    # No Vulkan isn't worth a word: drawing with OpenGL is a normal way to
    # run (most virtual machines have no Vulkan driver anyway). It only
    # joins the install command when something else is missing too.
    [ ${#required[@]} -eq 0 ] && return 0

    say "guiltty needs these libraries, and this system doesn't have them: ${required[*]}"
    for lib in "${required[@]}" "${optional[@]}"; do
        pkg=$(package_for "$lib")
        [ -n "$pkg" ] && packages+=("$pkg")
    done
    if [ -z "$family" ] || [ ${#packages[@]} -lt ${#required[@]} ]; then
        die "install them with your package manager, then run this script again"
    fi
    install_packages "${packages[@]}"
}

# --- Getting the release: downloaded, unpacked here, or built ---

download_release() {
    local tag version name url tmp
    need curl || die "curl is needed"
    need tar || die "tar is needed"
    need sha256sum || die "sha256sum is needed"
    [ "$(uname -m)" = x86_64 ] || die "the precompiled release is for x86_64 only; build from source (README)"

    tag="${GUILTTY_VERSION:-}"
    if [ -z "$tag" ]; then
        tag=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" |
            sed -n 's/.*"tag_name": *"\(v[0-9][0-9.]*\)".*/\1/p') ||
            die "can't reach GitHub to find the latest release"
        [ -n "$tag" ] || die "no release found on github.com/$REPO"
    fi
    # The tags are spelled v0.26.0; accept 0.26.0 too.
    case "$tag" in v*) ;; *) tag="v$tag" ;; esac
    version=${tag#v}
    name="guiltty-$version-x86_64-linux"
    url="https://github.com/$REPO/releases/download/$tag/$name.tar.gz"
    say "guiltty $tag: $url"

    tmp=$(mktemp -d)
    # shellcheck disable=SC2064 # expand $tmp now
    trap "rm -rf '$tmp'" EXIT
    curl -fSL --progress-bar -o "$tmp/$name.tar.gz" "$url" || die "download failed: $url"
    curl -fsSL -o "$tmp/$name.tar.gz.sha256" "$url.sha256" || die "download failed: $url.sha256"
    # The checksum catches a broken download; a tampered one would come
    # with a matching checksum, so HTTPS from github.com is the real guard.
    (cd "$tmp" && sha256sum --quiet -c "$name.tar.gz.sha256") || die "the download is damaged (checksum mismatch)"
    tar -xzf "$tmp/$name.tar.gz" -C "$tmp"
    release_dir="$tmp/$name/release"
}

# The two Erlang node commands mix needs on a fresh Elixir, the tools, and
# the build itself, into $APP.new.
build_from_source() {
    local here=$1 tool lib
    local -a missing=()
    for tool in mix make pkg-config glslc; do need "$tool" || missing+=("$tool"); done
    need gcc || need clang || missing+=("a C compiler (GCC 15 or Clang 19)")
    for lib in sdl3 freetype2 fontconfig harfbuzz libpng vulkan; do
        pkg-config --exists "$lib" 2>/dev/null || missing+=("$lib (development files)")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        warn "can't build guiltty, missing: ${missing[*]}"
        warn "the README lists what to install, or skip building: install the precompiled release with"
        warn "  curl -fsSL https://raw.githubusercontent.com/$REPO/master/install.sh | bash"
        exit 1
    fi

    # Mix fetches the dependencies with Hex, and telemetry builds with
    # rebar3. On a fresh Elixir both are missing, and Mix would stop to ask.
    (cd "$here" && mix local.hex --force --if-missing >/dev/null && mix local.rebar --force --if-missing >/dev/null)

    say "building guiltty (MIX_ENV=prod)..."
    rm -rf "$APP.new"
    (cd "$here" && MIX_ENV=prod mix deps.get --only prod >/dev/null &&
        MIX_ENV=prod mix release guiltty --overwrite --quiet --path "$APP.new")
}

# --- Putting it in place ---

install_release() {
    local version size icons
    # Swapped with two renames, so there's never a moment with no guiltty
    # installed: if anything stops the script here, one of the two is in place.
    stop_installed
    rm -rf "$APP.old"
    [ -e "$APP" ] && mv "$APP" "$APP.old"
    mv "$APP.new" "$APP"
    rm -rf "$APP.old"

    # The `guiltty` command is the release's small C client (book chapter
    # 23): it asks the running guiltty for a window, or starts guiltty; any
    # other argument (stop, remote, pid...) goes to the release's own
    # script. A link, so the client finds the release it belongs to.
    version=$(cut -d' ' -f2 "$APP/releases/start_erl.data")
    mkdir -p "$(dirname "$BIN")"
    rm -f "$BIN"
    ln -s "$APP/lib/guiltty-$version/priv/guiltty" "$BIN"

    icons="$APP/lib/guiltty-$version/priv/icons"
    for size in $SIZES; do
        install -D -m 644 "$icons/guiltty-$size.png" "$ICONS/${size}x${size}/apps/guiltty.png"
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
    if need desktop-file-validate; then desktop-file-validate "$DESKTOP"; fi
    refresh_desktop

    say "guiltty $version is installed: run guiltty, or find it in your menu"

    # Started from one of its tabs, the update closed every window: open
    # one, on the new version, so the update ends where it began.
    if $inside; then
        "$BIN" || say "couldn't start guiltty again: run guiltty"
    fi
    case ":$PATH:" in
    *":$(dirname "$BIN"):"*) ;;
    *) say "note: $(dirname "$BIN") isn't in your PATH; the menu entry works anyway" ;;
    esac
}

main() {
    local arg src here="" release_dir=""
    for arg in "$@"; do
        case "$arg" in
        --yes) yes=true ;;
        --uninstall) uninstall=true ;;
        *) die "usage: install.sh [--uninstall] [--yes]" ;;
        esac
    done

    [ "$(uname -s)" = Linux ] || die "guiltty runs on Linux only"

    if $uninstall; then
        do_uninstall
        exit 0
    fi

    # guiltty's node takes its cookie from ~/.erlang.cookie (book chapter
    # 20), and Erlang refuses to start if anyone but you can read that file.
    local cookie="$HOME/.erlang.cookie"
    # The mode's last two octal digits are the group's and others' bits:
    # both must be 0 (stat(1), %a).
    if [ -e "$cookie" ] && [ "$(stat -c %a "$cookie" | tail -c 3)" != 00 ]; then
        warn "$cookie can be read by other users; guiltty (and Erlang) won't use it."
        die "make it yours alone first: chmod 400 $cookie"
    fi

    detect_family

    # Where this script is: nowhere when piped from curl (download), in an
    # unpacked tarball (a release/ next to it), or in a git checkout.
    src="${BASH_SOURCE[0]:-}"
    [ -f "$src" ] && here=$(cd "$(dirname "$src")" && pwd)

    if [ -n "$here" ] && [ -d "$here/release" ]; then
        release_dir="$here/release"
    elif [ -n "$here" ] && [ -f "$here/mix.exs" ]; then
        build_from_source "$here"
    else
        download_release
    fi

    if [ -n "$release_dir" ]; then
        check_runtime_libs "$release_dir"
        rm -rf "$APP.new"
        mkdir -p "$(dirname "$APP")"
        cp -a "$release_dir" "$APP.new"
    fi

    install_release

    if [ -n "$here" ] && running "$here/_build/prod/rel/guiltty"; then
        say "note: a guiltty from _build/prod is running. Stop it first" \
            "($here/_build/prod/rel/guiltty/bin/guiltty stop): both use the node name guiltty@127.0.0.1."
    fi
}

# All of it is in functions, and this is the last line: piped into bash,
# the whole script is read before anything runs, so no command can read
# the rest of it from stdin by accident.
main "$@"

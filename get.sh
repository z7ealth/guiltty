#!/bin/sh
# Installs guiltty from its latest release, or updates it:
#
#   curl -fsSL https://raw.githubusercontent.com/z7ealth/guiltty/master/get.sh | sh
#
# Options (after `sh -s --` when piped):
#
#   --yes        install missing packages and stop a running guiltty
#                without asking
#   --dry-run    say what would be done, and do nothing
#
#   GUILTTY_VERSION=v0.18.1   a tag other than the latest
#   PREFIX=/somewhere         where install.sh puts it (default ~/.local)
#
# What it does:
#
#   1. reads /etc/os-release to know the distribution (openSUSE, Fedora,
#      Ubuntu/Debian, Arch, and those based on them);
#   2. finds which build packages are missing, shows the command that
#      installs them (with sudo) and asks before running it;
#   3. checks for Elixir 1.18 or newer on Erlang/OTP 26 or newer, and
#      stops with advice if there isn't one: the build needs it;
#   4. downloads the release's source (no git needed) into
#      ~/.local/src/guiltty-<version>;
#   5. runs its install.sh, which builds guiltty into ~/.local.
#
# Only step 2 uses root, and only after you say yes. Read this file before
# piping it into a shell: that's what it's for.
set -eu

REPO="z7ealth/guiltty"
SRC="$HOME/.local/src"

yes=false
dry=false
for arg in "$@"; do
    case "$arg" in
    --yes) yes=true ;;
    --dry-run) dry=true ;;
    *) echo "usage: get.sh [--yes] [--dry-run]" >&2; exit 2 ;;
    esac
done

say() { printf '%s\n' "$*"; }
warn() { printf 'guiltty: %s\n' "$*" >&2; }
die() { warn "$*"; exit 1; }

# A yes/no question. Piped into sh, stdin is this script, so the answer
# is read from the terminal itself.
ask() {
    $yes && return 0
    has_tty || die "can't ask (no terminal): run again with --yes"
    printf '%s [y/N] ' "$1" >/dev/tty
    read -r answer </dev/tty || return 1
    case "$answer" in y | Y | yes | Yes) return 0 ;; *) return 1 ;; esac
}

need() { command -v "$1" >/dev/null 2>&1; }

# A terminal to talk to. /dev/tty can exist and still not open (a
# container, cron, CI: no controlling terminal), so try opening it.
has_tty() { (exec </dev/tty) 2>/dev/null; }

# Runs a command with the terminal as its input when there is one: the
# package manager or install.sh may have a question too.
with_tty() {
    if has_tty; then "$@" </dev/tty; else "$@" </dev/null; fi
}

[ "$(uname -s)" = Linux ] || die "guiltty runs on Linux only"
need curl || die "curl is needed"
need tar || die "tar is needed"
need bash || die "bash is needed (install.sh is a bash script)"

# --- 1. The distribution ---

[ -r /etc/os-release ] || die "no /etc/os-release: can't tell which distribution this is"
# shellcheck disable=SC1091
. /etc/os-release
family=""
for id in ${ID:-} ${ID_LIKE:-}; do
    case "$id" in
    opensuse* | suse | sles) family=suse ;;
    fedora | rhel | centos) family=fedora ;;
    debian | ubuntu) family=debian ;;
    arch | archlinux) family=arch ;;
    esac
    [ -n "$family" ] && break
done

# --- 2. Build packages ---
#
# The same lists as the README. `is_installed` asks the package manager,
# so a package counts whether or not its files are where we'd look.

case "$family" in
suse)
    packages="gcc make pkg-config SDL3-devel freetype2-devel fontconfig-devel harfbuzz-devel
              libpng16-devel vulkan-devel shaderc tar gzip"
    elixir_packages="elixir erlang-epmd"
    is_installed() { rpm -q --whatprovides "$1" >/dev/null 2>&1; }
    install_cmd="zypper install"
    assume_yes="-y"
    ;;
fedora)
    packages="gcc make pkgconf-pkg-config SDL3-devel freetype-devel fontconfig-devel harfbuzz-devel
              libpng-devel vulkan-loader-devel vulkan-headers glslc tar gzip"
    elixir_packages="elixir"
    is_installed() { rpm -q --whatprovides "$1" >/dev/null 2>&1; }
    install_cmd="dnf install"
    assume_yes="-y"
    ;;
debian)
    packages="build-essential pkg-config libsdl3-dev libfreetype-dev libfontconfig-dev
              libharfbuzz-dev libpng-dev libvulkan-dev glslc tar gzip"
    elixir_packages="elixir erlang-dev"
    is_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed"; }
    install_cmd="apt install"
    assume_yes="-y"
    ;;
arch)
    packages="base-devel sdl3 freetype2 fontconfig harfbuzz libpng vulkan-icd-loader
              vulkan-headers shaderc tar gzip"
    elixir_packages="elixir"
    is_installed() { pacman -Q "$1" >/dev/null 2>&1; }
    install_cmd="pacman -S --needed"
    assume_yes="--noconfirm"
    ;;
*)
    warn "${PRETTY_NAME:-this distribution} isn't one this script knows."
    say "guiltty needs, as development packages: a C compiler with C23 (GCC 15 or"
    say "Clang 19), make, pkg-config, SDL3, FreeType, fontconfig, HarfBuzz, libpng,"
    say "Vulkan headers and loader, glslc (shaderc), and Elixir 1.18+ on OTP 26+."
    ask "Are they installed? Go on and build" || exit 1
    ;;
esac

# Elixir 1.18+ on OTP 26+, if one is on the PATH (a distribution's, asdf's,
# mise's...). Prints why not when it isn't.
elixir_ok() {
    need elixir || { echo "no elixir command"; return 1; }
    v=$(elixir -e 'IO.write(System.version())' 2>/dev/null) || { echo "elixir doesn't run"; return 1; }
    otp=$(elixir -e 'IO.write(System.otp_release())' 2>/dev/null) || otp=0
    major=${v%%.*}
    rest=${v#*.}
    minor=${rest%%.*}
    if [ "$major" -lt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -lt 18 ]; }; then
        echo "Elixir $v is older than 1.18"
        return 1
    fi
    if [ "$otp" -lt 26 ]; then
        echo "Erlang/OTP $otp is older than 26"
        return 1
    fi
    return 0
}

if [ -n "$family" ]; then
    # An Elixir that's good enough already (asdf's, say): don't add the
    # distribution's on top of it.
    if why=$(elixir_ok); then
        wanted="$packages"
    else
        wanted="$packages $elixir_packages"
    fi

    missing=""
    for p in $wanted; do
        is_installed "$p" || missing="$missing $p"
    done

    if [ -n "$missing" ]; then
        sudo=""
        [ "$(id -u)" -eq 0 ] || sudo="sudo "
        # With --yes, the package manager doesn't ask either; without it,
        # it asks its own question too, listing what else it pulls in.
        $yes && install_cmd="$install_cmd $assume_yes"
        cmd="$sudo$install_cmd$missing"
        [ "$family" = debian ] && cmd="${sudo}apt update && $cmd"
        say "These packages are missing:$missing"
        say "  $cmd"
        if $dry; then
            say "(dry run: not installing them)"
        elif ask "Install them now?"; then
            with_tty sh -c "$cmd"
        else
            die "not installed; run the command above yourself, then this script again"
        fi
    else
        say "Build packages: all there."
    fi
fi

# --- 3. Elixir ---

if ! why=$(elixir_ok); then
    if $dry; then
        warn "$why (the build would stop here)"
    else
        warn "$why: guiltty needs Elixir 1.18 or newer, on Erlang/OTP 26 or newer."
        say "Your distribution's may be too old. asdf installs any version, for you only:"
        say "  https://asdf-vm.com/guide/getting-started.html"
        say "  asdf plugin add erlang && asdf plugin add elixir"
        say "  asdf install erlang 28.1 && asdf install elixir 1.19.4-otp-28"
        say "  asdf set --home erlang 28.1 && asdf set --home elixir 1.19.4-otp-28"
        say "Then run this script again."
        exit 1
    fi
else
    say "Elixir: $(elixir -e 'IO.write(System.version())'), on OTP $(elixir -e 'IO.write(System.otp_release())')."
fi

# C23 (constexpr, #embed...): GCC 15 or Clang 19. Older compilers fail
# halfway through the build; better to say so now.
if need cc && ! printf 'constexpr int x = 0;\nint main(void) { return x; }\n' |
    cc -std=c23 -x c - -o /dev/null 2>/dev/null; then
    warn "your C compiler doesn't speak C23: guiltty needs GCC 15 or newer (or Clang 19)"
    $dry || exit 1
fi

# --- 4. The source ---

# The newest tag, by version order (the API lists them by name).
version="${GUILTTY_VERSION:-}"
if [ -z "$version" ]; then
    version=$(curl -fsSL "https://api.github.com/repos/$REPO/tags?per_page=100" |
        sed -n 's/.*"name": *"\(v[0-9][0-9.]*\)".*/\1/p' | sort -V | tail -n 1) ||
        die "can't reach GitHub to find the latest version"
    [ -n "$version" ] || die "no release tags found on github.com/$REPO"
fi
dir="$SRC/guiltty-${version#v}"
url="https://github.com/$REPO/archive/refs/tags/$version.tar.gz"
say "guiltty $version: $url"
say "  into $dir"

if $dry; then
    say "(dry run: not downloading or building)"
    exit 0
fi

mkdir -p "$SRC"
tmp=$(mktemp -d "$SRC/.guiltty.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$url" | tar -xz -C "$tmp" || die "download failed: $url"
# The tarball holds one folder, guiltty-<version>/.
rm -rf "$dir"
mv "$tmp"/guiltty-* "$dir"

# --- 5. Build and install ---

set --
$yes && set -- --yes
# install.sh may ask (stopping a running guiltty): give it the terminal.
with_tty bash "$dir/install.sh" "$@"

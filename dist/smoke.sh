#!/bin/bash
# Tries a precompiled release on fresh distributions, each in a container
# that has nothing but its base image (book chapter 17):
#
#   dist/smoke.sh _build/dist/guiltty-0.26.0-x86_64-linux.tar.gz [image...]
#
# In each, install.sh --yes installs the libraries it finds missing, then
# guiltty: `guiltty version` must answer, both NIFs must load, and the
# renderers must draw test/fixtures/replay/session.msgs offscreen, on
# Mesa's software drivers. `make dist-check` runs it on the newest tarball,
# and so does the release workflow before publishing anything.
set -euo pipefail

tarball=${1:?usage: dist/smoke.sh <tarball> [image...]}
shift
images=("$@")
[ ${#images[@]} -gt 0 ] || images=(ubuntu:24.04 debian:12 fedora:latest archlinux:latest opensuse/tumbleweed)
root=$(cd "$(dirname "$0")/.." && pwd)

# What a desktop has and a base image doesn't: Mesa (software OpenGL and
# Vulkan), the GL dispatch libraries and a font. install.sh doesn't
# install these, because a real desktop always has them.
desktop_packages() {
    case "$1" in
    ubuntu:* | debian:*)
        echo "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y mesa-vulkan-drivers libgl1 libgl1-mesa-dri libegl1 libegl-mesa0 fonts-dejavu-core" ;;
    fedora:*) echo "dnf install -y mesa-vulkan-drivers mesa-dri-drivers mesa-libEGL mesa-libGL dejavu-sans-mono-fonts" ;;
    archlinux:*) echo "pacman -Syu --noconfirm vulkan-swrast mesa libglvnd ttf-dejavu" ;;
    opensuse/*) echo "zypper -n in libvulkan_lvp Mesa-dri Mesa-libEGL1 Mesa-libGL1 libglvnd dejavu-fonts" ;;
    *) echo "true" ;;
    esac
}

# Debian 12's lavapipe has no VK_EXT_headless_surface, so its Vulkan
# renderer can't draw offscreen. That's a limit of the test (a desktop
# presents to a window), so there only OpenGL is tried.
renderers() {
    case "$1" in
    debian:12) echo guiltty_gl ;;
    *) echo guiltty_vk guiltty_gl ;;
    esac
}

# A scratch copy, so the container sees only these two files (and SELinux
# relabels the copy, not the repository).
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$tarball" "$work/guiltty.tar.gz"
cp "$root/test/fixtures/replay/session.msgs" "$work/"

failed=()
for image in "${images[@]}"; do
    echo "=== $image"
    # shellcheck disable=SC2016 # expanded in the container
    if docker run --rm -v "$work:/w:ro,z" "$image" bash -c '
        set -eu
        export LANG=C.UTF-8
        { '"$(desktop_packages "$image")"'; } >/tmp/packages.log 2>&1 || { tail -20 /tmp/packages.log; exit 1; }
        cd /tmp && tar -xzf /w/guiltty.tar.gz
        bash /tmp/guiltty-*/install.sh --yes >/tmp/install.log 2>&1 || { tail -20 /tmp/install.log; exit 1; }
        ~/.local/bin/guiltty version
        ~/.local/lib/guiltty/bin/guiltty eval "Code.ensure_loaded!(Guiltty.TextNif); Code.ensure_loaded!(Guiltty.Session.PtyNif); IO.puts(\"NIFs load\")"
        for r in '"$(renderers "$image")"'; do
            SDL_VIDEO_DRIVER=offscreen timeout 60 ~/.local/lib/guiltty/lib/guiltty-*/priv/$r \
                --replay /w/session.msgs --screenshot /tmp/$r.ppm >/tmp/$r.log 2>&1 || true
            if [ -s /tmp/$r.ppm ]; then echo "$r draws"; else echo "$r FAILED:"; tail -5 /tmp/$r.log; exit 1; fi
        done
    '; then
        echo "=== $image: ok"
    else
        echo "=== $image: FAILED"
        failed+=("$image")
    fi
done

if [ ${#failed[@]} -gt 0 ]; then
    echo "failed on: ${failed[*]}" >&2
    exit 1
fi
echo "all ok: ${images[*]}"

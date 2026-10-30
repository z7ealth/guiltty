#!/bin/sh
# Renders the logo into the icons guiltty installs (`make icons`):
#
#   priv/icons/logo.svg        -> guiltty-32.png .. guiltty-256.png, priv/guiltty.bmp
#   priv/icons/logo-small.svg  -> guiltty-16.png, guiltty-24.png (simpler, for tiny sizes)
#
# SVG needs a renderer: rsvg-convert if it's installed (zypper install
# rsvg-convert), otherwise headless Chromium. ImageMagick then makes the
# BMP the renderer uses as its window icon (SDL3 reads only BMP).
set -eu
icons=priv/icons
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# render SVG SIZE OUT
render() {
    if command -v rsvg-convert >/dev/null; then
        rsvg-convert -w "$2" -h "$2" "$1" -o "$3"
    else
        # Chromium draws the SVG big once; ImageMagick scales it down.
        big="$tmp/$(basename "$1").png"
        if [ ! -f "$big" ]; then
            printf '<body style="margin:0"><img src="file://%s" style="width:1024px;height:1024px;display:block">' \
                "$(realpath "$1")" >"$tmp/page.html"
            chromium --headless --disable-gpu --no-sandbox --hide-scrollbars \
                --default-background-color=00000000 --window-size=1024,1024 \
                --screenshot="$big" "file://$tmp/page.html" 2>/dev/null
        fi
        magick "$big" -resize "$2x$2" "$3"
    fi
}

for size in 16 24; do render "$icons/logo-small.svg" "$size" "$icons/guiltty-$size.png"; done
for size in 32 48 64 128 256; do render "$icons/logo.svg" "$size" "$icons/guiltty-$size.png"; done
magick "$icons/guiltty-128.png" -define bmp:format=bmp4 priv/guiltty.bmp
echo "icons made from $icons/logo.svg and logo-small.svg"

#!/bin/sh
# Runs inside dist/Dockerfile: builds the release and packs it into
# $1/guiltty-<version>-x86_64-linux.tar.gz. Not meant to run on your own
# machine: `make dist` is.
set -eu
out="$1"

# The Makefile links SDL3 in and skips the -dbg renderers when
# GUILTTY_DIST is set; mix release builds the C through it (elixir_make).
export GUILTTY_DIST=1
version=$(sed -n 's/^ *version: "\(.*\)",$/\1/p' mix.exs)
name="guiltty-$version-x86_64-linux"
stage="/tmp/$name"

mix release guiltty --overwrite --quiet --path "$stage/release"

# A release copies all of priv/: drop the -dbg renderers in case any
# were there, and debug symbols from the rest (much smaller; a crash in a
# release renderer is reproduced with a source build anyway).
priv=$(echo "$stage"/release/lib/guiltty-*/priv)
rm -f "$priv"/*-dbg
binaries="$priv/guiltty $priv/guiltty_vk $priv/guiltty_gl $priv/pty_nif.so $priv/text_nif.so"
# shellcheck disable=SC2086
strip --strip-unneeded $binaries

cp install.sh LICENSE "$stage/"

# What the tarball carries from others, with their licenses (the
# Dockerfile kept a copy of each): Erlang and Elixir (Apache 2.0, with
# some parts under BSD and MIT), SDL3 (zlib), ncurses (MIT-style, linked
# into Erlang) and telemetry (Apache 2.0).
cp -r /opt/licenses "$stage/licenses"
cp deps/telemetry/LICENSE "$stage/licenses/telemetry.txt"

# Nothing outside libc, libm and the desktop libraries checked by
# install.sh may be needed: SDL3 in particular must be linked in.
for f in $binaries; do
    if readelf -d "$f" | grep NEEDED | grep -v -E 'lib(c|m|fontconfig|freetype|harfbuzz|png16|vulkan)\.so'; then
        echo "dist: $f needs a library install.sh doesn't check" >&2
        exit 1
    fi
done

# Erlang built from source keeps its debug symbols: 56 MB of beam.smp
# out of 60. Stripped, the tarball is a third of the size.
for f in "$stage"/release/erts-*/bin/*; do
    readelf -h "$f" >/dev/null 2>&1 && strip --strip-unneeded "$f"
done

# The bundled Erlang may need only what every Linux has: the C and C++
# runtimes and zlib. libtinfo in particular must be linked in
# (dist/Dockerfile).
for f in "$stage"/release/erts-*/bin/*; do
    readelf -h "$f" >/dev/null 2>&1 || continue # a script, not a binary
    if readelf -d "$f" | grep NEEDED | grep -v -E 'lib(c|m|z|stdc\+\+|gcc_s)\.so'; then
        echo "dist: $f needs a library a user may not have" >&2
        exit 1
    fi
done

mkdir -p "$out"
tar -C /tmp -czf "$out/$name.tar.gz" "$name"
(cd "$out" && sha256sum "$name.tar.gz" >"$name.tar.gz.sha256")
echo "dist: $out/$name.tar.gz"

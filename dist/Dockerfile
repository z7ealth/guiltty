# The precompiled release (book chapter 17, "The precompiled release").
# `make dist` runs it:
#
#   docker build -f dist/Dockerfile --target export --output _build/dist .
#
# and _build/dist/ gets guiltty-<version>-x86_64-linux.tar.gz.
#
# Why Debian 12: a program built against one glibc runs on that glibc and
# any newer one, never an older one (glibc's symbol versioning). Debian
# 12 has glibc 2.36, so the tarball runs on Debian 12, Ubuntu 24.04 and
# 26.04, and every current Fedora, Arch and openSUSE. It also has glslc
# and the X11/Wayland headers SDL needs. What it lacks we bring: a C23
# compiler (Clang from apt.llvm.org), and SDL3, built here.

# --- The toolchain: changes rarely, so Docker caches it ---

FROM debian:bookworm-20261027 AS toolchain

ARG OTP=29.1.2
ARG OTP_SHA256=c79966661e35fe4aff8ec003db63682e3b33b10b672220d51bf93c0a9244b049
ARG ELIXIR=1.20.5
ARG ELIXIR_SHA256=f424d6f0bb710a1d4898f2645d8ad6cab3f5eab8d71848c0dda2579d3a8e8a06
ARG CLANG=20
ARG SDL=3.4.18
ARG SDL_SHA256=9c75cf16330322c217dedd2e0609f1124f1b54b8633e763467b4684d0f4334a3

# Build tools; the renderer's libraries (these stay dynamic: every desktop
# has them); Vulkan and glslc; and the headers SDL needs for X11, Wayland,
# EGL, input methods (IBus over D-Bus) and audio. SDL loads each of those
# with dlopen at run time, so a machine without, say, PipeWire still runs.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg make cmake ninja-build pkg-config unzip \
      gcc g++ perl libssl-dev libncurses-dev \
      libfreetype-dev libfontconfig-dev libharfbuzz-dev libpng-dev \
      libvulkan-dev glslc \
      libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev libxss-dev \
      libxtst-dev libxfixes-dev libxkbcommon-dev libwayland-dev wayland-protocols \
      libegl-dev libgl-dev libdrm-dev libgbm-dev libdecor-0-dev \
      libdbus-1-dev libibus-1.0-dev libudev-dev \
      libasound2-dev libpulse-dev libpipewire-0.3-dev \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /opt/licenses/erlang \
 && cp /usr/share/doc/libncurses-dev/copyright /opt/licenses/ncurses.txt

# Erlang, built here, because the release carries it (its ERTS) to the
# user's machine. Prebuilt Erlangs link ncurses' libtinfo dynamically,
# and that broke on two distributions: openSUSE's libtinfo lacks a
# versioned symbol Debian's has (beam.smp won't start), and Fedora's
# warns about it on every command. So libtinfo goes in statically: with
# only the .a left to find, the linker takes it. SCTP is off too: unused,
# and the VM warns when it can't find libsctp. OpenSSL is only for Hex
# (fetching dependencies here); the release doesn't include crypto.
RUN cd /usr/lib/x86_64-linux-gnu && rm -f libtinfo.so libncurses.so libncursesw.so \
 && curl -fsSLo /tmp/otp.tar.gz https://github.com/erlang/otp/releases/download/OTP-$OTP/otp_src_$OTP.tar.gz \
 && echo "$OTP_SHA256  /tmp/otp.tar.gz" | sha256sum -c - \
 && mkdir /tmp/otp && tar -xzf /tmp/otp.tar.gz -C /tmp/otp --strip-components=1 \
 && cd /tmp/otp && ./configure --prefix=/opt/otp --disable-sctp \
      --without-javac --without-jinterface --without-wx --without-odbc \
      --without-debugger --without-observer --without-et --without-megaco \
 && make -j"$(nproc)" && make install \
 && cp -r LICENSE.txt LICENSES /opt/licenses/erlang/ \
 && rm -rf /tmp/otp /tmp/otp.tar.gz

# Elixir is bytecode: the precompiled one for this OTP is all we need.
RUN curl -fsSLo /tmp/elixir.zip https://github.com/elixir-lang/elixir/releases/download/v$ELIXIR/elixir-otp-${OTP%%.*}.zip \
 && echo "$ELIXIR_SHA256  /tmp/elixir.zip" | sha256sum -c - \
 && unzip -q /tmp/elixir.zip -d /opt/elixir && rm /tmp/elixir.zip \
 && cp /opt/elixir/LICENSE /opt/licenses/elixir.txt

# C23 with #embed: Clang 19 or newer. Debian 12's is 14, so LLVM's own
# packages (apt.llvm.org), pinned to one major version.
RUN curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key | gpg --dearmor -o /usr/share/keyrings/llvm.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/llvm.gpg] http://apt.llvm.org/bookworm/ llvm-toolchain-bookworm-$CLANG main" \
      > /etc/apt/sources.list.d/llvm.list \
 && apt-get update && apt-get install -y --no-install-recommends clang-$CLANG lld-$CLANG \
 && rm -rf /var/lib/apt/lists/*

# SDL3, as a static library (zlib license: fine to link in). Linked into
# the renderers, it leaves no libSDL3.so to find on the user's machine,
# which matters on Ubuntu 24.04: it has no SDL3 package at all.
# Position-independent, because the renderers are PIE (Makefile, EXE).
RUN curl -fsSLo /tmp/sdl.tar.gz https://github.com/libsdl-org/SDL/releases/download/release-$SDL/SDL3-$SDL.tar.gz \
 && echo "$SDL_SHA256  /tmp/sdl.tar.gz" | sha256sum -c - \
 && mkdir /tmp/sdl && tar -xzf /tmp/sdl.tar.gz -C /tmp/sdl --strip-components=1 \
 && cmake -S /tmp/sdl -B /tmp/sdl/build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=clang-$CLANG \
      -DCMAKE_INSTALL_PREFIX=/opt/sdl3 -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
      -DSDL_X11=ON -DSDL_WAYLAND=ON -DSDL_WAYLAND_LIBDECOR=ON -DSDL_IBUS=ON \
 && cmake --build /tmp/sdl/build && cmake --install /tmp/sdl/build \
 && cp /tmp/sdl/LICENSE.txt /opt/licenses/sdl3.txt \
 && rm -rf /tmp/sdl /tmp/sdl.tar.gz

ENV PATH=/opt/elixir/bin:/opt/otp/bin:$PATH \
    CC=clang-$CLANG \
    PKG_CONFIG_PATH=/opt/sdl3/lib/pkgconfig \
    MIX_ENV=prod \
    LANG=C.UTF-8

RUN mix local.hex --force && mix local.rebar --force

# --- The build ---

FROM toolchain AS build
WORKDIR /src
# Dependencies first, so editing guiltty's code doesn't fetch them again.
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
COPY . .
RUN sh dist/build.sh /out

# --- What `--output` writes out: the tarball, nothing else ---

FROM scratch AS export
COPY --from=build /out/ /

# Built by elixir_make during `mix compile`. It exports ERTS_INCLUDE_DIR;
# the fallback lets you run `make` by hand too.
#
#   make             the PTY NIF and both renderers, Vulkan and OpenGL
#                    (each in a normal and a debug build)
#   make debug       only the debug renderers: AddressSanitizer and UBSan,
#                    and the Vulkan validation layers in priv/guiltty_vk-dbg
#   make analyze     GCC's and Clang's static analyzers over all the C:
#                    paths that leak, use freed memory, dereference null,
#                    read uninitialized values
#   make fuzz        the fuzz targets (Clang's libFuzzer), into _build/fuzz/
#   make fuzz-run    run each for FUZZ_TIME seconds (default 600)
#   make valgrind    replay the recordings in both renderers under Valgrind
#   make bench       throughput: parser + grid alone, then a real window
#   make width-table regenerate the Unicode width table from glibc
#   make text-table  regenerate the text NIF's codepoint table
#   make icons       regenerate the icons from priv/icons/logo.svg

ERTS_INCLUDE_DIR ?= $(shell erl -noshell -eval 'io:format("~s/erts-~s/include", [code:root_dir(), erlang:system_info(version)]), halt().')

CC ?= gcc
WARNINGS = -Wall -Wextra -Wpedantic -Wformat=2 -Wshadow -Wvla -Wnull-dereference
CFLAGS_C23 = -std=c23 $(WARNINGS) -g $(HARDEN)
SANITIZE = -O1 -fsanitize=address,undefined -fno-omit-frame-pointer

# Hardening: if a bug slips through, make it crash cleanly instead of
# being exploitable. FORTIFY_SOURCE checks buffer sizes in libc calls it
# can see (memcpy, snprintf...); the stack protector catches overwritten
# return addresses; stack-clash keeps big stack frames from jumping the
# guard page; cf-protection marks branch targets for the CPU (Intel CET);
# zero-initialized locals turn "uninitialized" bugs into predictable ones.
# Linking: position-independent executables (full ASLR), RELRO and now
# (the GOT is read-only after startup), and a stack that can't execute.
HARDEN = -D_FORTIFY_SOURCE=3 -fstack-protector-strong -fstack-clash-protection \
         -fcf-protection -ftrivial-auto-var-init=zero
HARDEN_LD = -Wl,-z,relro,-z,now,-z,noexecstack
EXE = -fPIE -pie $(HARDEN_LD)

PRIV = priv
NIF = $(PRIV)/pty_nif.so
# Text to grid cells, the hot path of printing (book chapter 22).
TEXT_NIF = $(PRIV)/text_nif.so
# The `guiltty` command: a small client for the running guiltty's socket
# (book chapter 23). It links only the C library.
CLIENT = $(PRIV)/guiltty

RENDERER_CORE = $(wildcard c_src/renderer/core/*.c)
RENDERER_HEADERS = $(wildcard c_src/renderer/core/*.h)
RENDERER_DEPS = sdl3 freetype2 fontconfig harfbuzz libpng
RENDERER_CFLAGS = $(shell pkg-config --cflags $(RENDERER_DEPS))
RENDERER_LIBS = $(shell pkg-config --libs $(RENDERER_DEPS))

GL_SRC = c_src/renderer/gl/gl_backend.c
GL_SHADERS = $(wildcard c_src/renderer/gl/shaders/*)
RENDERER_GL = $(PRIV)/guiltty_gl

# The Vulkan backend's shaders are compiled to SPIR-V by glslc (from
# shaderc) and baked into the binary with #embed. The .spv files are build
# products (gitignored).
VK_SRC = c_src/renderer/vk/vk_backend.c
VK_SHADER_DIR = c_src/renderer/vk/shaders
VK_SPV = $(VK_SHADER_DIR)/cell.vert.spv $(VK_SHADER_DIR)/cell.frag.spv \
         $(VK_SHADER_DIR)/image.vert.spv $(VK_SHADER_DIR)/image.frag.spv
VK_CFLAGS = $(shell pkg-config --cflags vulkan)
VK_LIBS = $(shell pkg-config --libs vulkan)
RENDERER_VK = $(PRIV)/guiltty_vk

DEBUG_RENDERERS = $(RENDERER_VK)-dbg $(RENDERER_GL)-dbg

# The precompiled release (`make dist`, dist/build.sh) sets GUILTTY_DIST:
# SDL3 is linked in statically, so `--static` adds what SDL itself needs
# from libc; and no -dbg renderers, which need the sanitizer runtimes.
ifdef GUILTTY_DIST
RENDERER_LIBS = $(shell pkg-config --libs --static sdl3) $(shell pkg-config --libs freetype2 fontconfig harfbuzz libpng)
DEBUG_RENDERERS =
endif

all: $(NIF) $(TEXT_NIF) $(CLIENT) $(RENDERER_VK) $(RENDERER_GL) $(DEBUG_RENDERERS)

$(CLIENT): c_src/client/guiltty.c
	@mkdir -p $(PRIV)
	$(CC) $(CFLAGS_C23) $(EXE) -O2 -o $@ $<

# A NIF is built for one Erlang (erl_nif.h's NIF version): switching
# Erlang (asdf) must rebuild it, though no source changed, or the other
# Erlang refuses to load it. The stamp's name is the erts it was built for.
ERTS_STAMP = _build/erts/$(notdir $(ERTS_INCLUDE_DIR:/include=))

$(ERTS_STAMP):
	@rm -rf _build/erts && mkdir -p _build/erts && touch $@

$(NIF): c_src/pty_nif.c $(ERTS_STAMP)
	@mkdir -p $(PRIV)
	$(CC) $(CFLAGS_C23) -O2 -fPIC -shared $(HARDEN_LD) -I$(ERTS_INCLUDE_DIR) -o $@ $<

$(TEXT_NIF): c_src/text_nif.c c_src/text_table.h $(ERTS_STAMP)
	@mkdir -p $(PRIV)
	$(CC) $(CFLAGS_C23) -O2 -fPIC -shared $(HARDEN_LD) -I$(ERTS_INCLUDE_DIR) -o $@ $<

$(RENDERER_GL): $(RENDERER_CORE) $(RENDERER_HEADERS) $(GL_SRC) $(GL_SHADERS)
	@mkdir -p $(PRIV)
	$(CC) $(CFLAGS_C23) $(EXE) -O2 $(RENDERER_CFLAGS) -o $@ $(RENDERER_CORE) $(GL_SRC) $(RENDERER_LIBS) -lm

debug: $(RENDERER_VK)-dbg $(RENDERER_GL)-dbg

$(RENDERER_GL)-dbg: $(RENDERER_CORE) $(RENDERER_HEADERS) $(GL_SRC) $(GL_SHADERS)
	@mkdir -p $(PRIV)
	$(CC) $(CFLAGS_C23) $(EXE) $(SANITIZE) $(RENDERER_CFLAGS) -o $@ $(RENDERER_CORE) $(GL_SRC) $(RENDERER_LIBS) -lm

$(VK_SHADER_DIR)/%.spv: $(VK_SHADER_DIR)/% $(VK_SHADER_DIR)/frame.glsl
	glslc --target-env=vulkan1.3 -O -o $@ $<

$(RENDERER_VK): $(RENDERER_CORE) $(RENDERER_HEADERS) $(VK_SRC) $(VK_SPV)
	@mkdir -p $(PRIV)
	$(CC) $(CFLAGS_C23) $(EXE) -O2 $(RENDERER_CFLAGS) $(VK_CFLAGS) -o $@ $(RENDERER_CORE) $(VK_SRC) $(RENDERER_LIBS) $(VK_LIBS) -lm

$(RENDERER_VK)-dbg: $(RENDERER_CORE) $(RENDERER_HEADERS) $(VK_SRC) $(VK_SPV)
	@mkdir -p $(PRIV)
	$(CC) $(CFLAGS_C23) $(EXE) $(SANITIZE) -DGUILTTY_VK_VALIDATION $(RENDERER_CFLAGS) $(VK_CFLAGS) -o $@ $(RENDERER_CORE) $(VK_SRC) $(RENDERER_LIBS) $(VK_LIBS) -lm

# Both analyzers follow each function's paths symbolically, so they find
# bugs no test happened to walk into, and each catches things the other
# misses. They're slow, so they aren't part of `all`. Any finding fails.
ANALYZE_GCC = $(CC) $(CFLAGS_C23) -O1 -fanalyzer -c -o /dev/null
ANALYZE_CLANG = clang -std=c23 --analyze -Xclang -analyzer-werror -o /dev/null

analyze: $(VK_SPV)
	$(ANALYZE_GCC) -I$(ERTS_INCLUDE_DIR) c_src/pty_nif.c
	$(ANALYZE_CLANG) -I$(ERTS_INCLUDE_DIR) c_src/pty_nif.c
	$(ANALYZE_GCC) -I$(ERTS_INCLUDE_DIR) c_src/text_nif.c
	$(ANALYZE_CLANG) -I$(ERTS_INCLUDE_DIR) c_src/text_nif.c
	$(ANALYZE_GCC) c_src/client/guiltty.c
	$(ANALYZE_CLANG) c_src/client/guiltty.c
	for f in $(RENDERER_CORE) $(GL_SRC); do \
	  $(ANALYZE_GCC) $(RENDERER_CFLAGS) $$f && $(ANALYZE_CLANG) $(RENDERER_CFLAGS) $$f || exit 1; \
	done
	$(ANALYZE_GCC) $(RENDERER_CFLAGS) $(VK_CFLAGS) $(VK_SRC)
	$(ANALYZE_CLANG) $(RENDERER_CFLAGS) $(VK_CFLAGS) $(VK_SRC)

# Fuzzing: libFuzzer feeds each target millions of inputs, mutating the
# ones that reach new code, under ASan and UBSan. Built with Clang (GCC has
# no libFuzzer), without the hardening flags: they'd hide bugs from the
# sanitizers. Seeds are in test/fixtures/fuzz/<target>/; what the fuzzer
# learns goes in _build/fuzz/corpus/, crashes in _build/fuzz/crashes/.
FUZZ_DIR = _build/fuzz
FUZZ_CC = clang -std=c23 -g -O1 -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=all
FUZZ_TARGETS = $(FUZZ_DIR)/fuzz_messages $(FUZZ_DIR)/fuzz_framing
FUZZ_TIME ?= 600
FUZZ_CORE = $(filter-out c_src/renderer/core/main.c,$(RENDERER_CORE))

fuzz: $(FUZZ_TARGETS)

$(FUZZ_DIR)/fuzz_messages: c_src/fuzz/fuzz_messages.c $(RENDERER_CORE) $(RENDERER_HEADERS)
	@mkdir -p $(FUZZ_DIR)
	$(FUZZ_CC) $(RENDERER_CFLAGS) -o $@ $< $(FUZZ_CORE) $(RENDERER_LIBS) -lm

$(FUZZ_DIR)/fuzz_framing: c_src/fuzz/fuzz_framing.c c_src/renderer/core/protocol.c c_src/renderer/core/protocol.h
	@mkdir -p $(FUZZ_DIR)
	$(FUZZ_CC) -o $@ $< c_src/renderer/core/protocol.c

fuzz-run: $(FUZZ_TARGETS)
	for t in messages framing; do \
	  mkdir -p $(FUZZ_DIR)/corpus/$$t $(FUZZ_DIR)/crashes; \
	  $(FUZZ_DIR)/fuzz_$$t -max_total_time=$(FUZZ_TIME) -artifact_prefix=$(FUZZ_DIR)/crashes/$$t- \
	    $(FUZZ_DIR)/corpus/$$t test/fixtures/fuzz/$$t || exit 1; \
	done

# Valgrind runs the release renderers (no sanitizers: they don't mix) on
# the recorded sessions, on SDL's offscreen driver and Mesa's software
# Vulkan (lavapipe), so no GPU or display is needed. It catches what ASan
# can't, like branching on uninitialized memory. Any error or leak fails.
VALGRIND = SDL_VIDEO_DRIVER=offscreen \
  VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json \
  valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite \
  --track-origins=yes --num-callers=30 --quiet
REPLAYS = test/fixtures/replay/session.msgs test/fixtures/fuzz/messages/all.msgs \
          test/fixtures/fuzz/messages/images.msgs

valgrind: $(RENDERER_GL) $(RENDERER_VK)
	@mkdir -p $(FUZZ_DIR)
	for r in $(RENDERER_GL) $(RENDERER_VK); do for f in $(REPLAYS); do \
	  echo "== $$r $$f"; \
	  $(VALGRIND) $$r --replay $$f --screenshot $(FUZZ_DIR)/valgrind.ppm || exit 1; \
	done; done

# Benchmarks (book chapter 22). They need the release renderer, so `all`
# first. The config is ignored (GUILTTY_CONFIG points nowhere): defaults
# make runs comparable. Time to window is bench/time_to_window.sh, run
# with hyperfine from another terminal (it needs a window manager).
bench: all
	mix run --no-start bench/throughput.exs
	GUILTTY_CONFIG=/nonexistent mix run --no-start bench/end_to_end.exs

# The Unicode width table comes from glibc's wcwidth(3). It's checked in;
# rebuild it after a glibc upgrade.
WIDTH_TABLE = lib/guiltty/unicode/width_table.ex

width-table:
	$(CC) $(CFLAGS_C23) -o $(PRIV)/gen_width c_src/tools/gen_width.c
	$(PRIV)/gen_width > $(WIDTH_TABLE)
	rm -f $(PRIV)/gen_width
	mix format $(WIDTH_TABLE)

# The text NIF's codepoint classes: the grapheme break property from the
# Unicode Character Database, widths from the width table above. Checked
# in; rebuild after `make width-table`. UNICODE_VERSIONS are those of the
# OTPs guiltty supports (unicode_util:spec_version()): OTP 26 to 29. Add
# one when a new OTP brings a new Unicode version.
UNICODE_VERSIONS = 15.0.0 15.1.0 16.0.0 17.0.0
TEXT_TABLE = c_src/text_table.h

text-table:
	@mkdir -p _build/ucd
	for v in $(UNICODE_VERSIONS); do \
	  curl -sSfo _build/ucd/GraphemeBreakProperty-$$v.txt \
	    https://www.unicode.org/Public/$$v/ucd/auxiliary/GraphemeBreakProperty.txt || exit 1; \
	done
	mix run --no-start c_src/tools/gen_text_table.exs $(TEXT_TABLE) \
	  $(foreach v,$(UNICODE_VERSIONS),_build/ucd/GraphemeBreakProperty-$(v).txt)

# The icons, made from the logo (priv/icons/logo.svg, and logo-small.svg
# for 16 and 24 pixels): PNGs in the sizes desktops look for, and a BMP
# the renderer loads as its window icon. They're checked in; run this
# after changing the logo.
icons:
	sh c_src/tools/icons.sh

# The precompiled release, built in a container on an older glibc so it
# runs on most distributions (dist/Dockerfile, book chapter 17). Needs
# Docker with BuildKit; the first run builds the toolchain (a few
# minutes), later runs reuse it.
dist:
	rm -rf _build/dist
	docker build -f dist/Dockerfile --target export --output _build/dist .

# Installs that tarball in fresh containers of five distributions and
# checks it runs (dist/smoke.sh). Pulls the images the first time.
dist-check:
	bash dist/smoke.sh _build/dist/guiltty-*-x86_64-linux.tar.gz

clean:
	rm -f $(NIF) $(TEXT_NIF) $(CLIENT) $(RENDERER_GL) $(RENDERER_GL)-dbg $(RENDERER_VK) $(RENDERER_VK)-dbg $(VK_SPV)

.PHONY: all debug clean analyze fuzz fuzz-run valgrind bench width-table text-table icons dist dist-check

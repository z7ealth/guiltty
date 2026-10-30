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
#   make width-table regenerate the Unicode width table from glibc
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

RENDERER_CORE = $(wildcard c_src/renderer/core/*.c)
RENDERER_HEADERS = $(wildcard c_src/renderer/core/*.h)
RENDERER_DEPS = sdl3 freetype2 fontconfig harfbuzz
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
VK_SPV = $(VK_SHADER_DIR)/cell.vert.spv $(VK_SHADER_DIR)/cell.frag.spv
VK_CFLAGS = $(shell pkg-config --cflags vulkan)
VK_LIBS = $(shell pkg-config --libs vulkan)
RENDERER_VK = $(PRIV)/guiltty_vk

all: $(NIF) $(RENDERER_VK) $(RENDERER_VK)-dbg $(RENDERER_GL) $(RENDERER_GL)-dbg

$(NIF): c_src/pty_nif.c
	@mkdir -p $(PRIV)
	$(CC) $(CFLAGS_C23) -O2 -fPIC -shared $(HARDEN_LD) -I$(ERTS_INCLUDE_DIR) -o $@ $< -lutil

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
	for f in $(RENDERER_CORE) $(GL_SRC); do \
	  $(ANALYZE_GCC) $(RENDERER_CFLAGS) $$f && $(ANALYZE_CLANG) $(RENDERER_CFLAGS) $$f || exit 1; \
	done
	$(ANALYZE_GCC) $(RENDERER_CFLAGS) $(VK_CFLAGS) $(VK_SRC)
	$(ANALYZE_CLANG) $(RENDERER_CFLAGS) $(VK_CFLAGS) $(VK_SRC)

# The Unicode width table comes from glibc's wcwidth(3). It's checked in;
# rebuild it after a glibc upgrade.
WIDTH_TABLE = lib/guiltty/unicode/width_table.ex

width-table:
	$(CC) $(CFLAGS_C23) -o $(PRIV)/gen_width c_src/tools/gen_width.c
	$(PRIV)/gen_width > $(WIDTH_TABLE)
	rm -f $(PRIV)/gen_width
	mix format $(WIDTH_TABLE)

# The icons, made from the logo (priv/icons/logo.svg, and logo-small.svg
# for 16 and 24 pixels): PNGs in the sizes desktops look for, and a BMP
# the renderer loads as its window icon. They're checked in; run this
# after changing the logo.
icons:
	sh c_src/tools/icons.sh

clean:
	rm -f $(NIF) $(RENDERER_GL) $(RENDERER_GL)-dbg $(RENDERER_VK) $(RENDERER_VK)-dbg $(VK_SPV)

.PHONY: all debug clean analyze width-table icons

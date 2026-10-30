# Built by elixir_make during `mix compile`. It exports ERTS_INCLUDE_DIR;
# the fallback lets you run `make` by hand too.
#
#   make             the PTY NIF and both renderers, Vulkan and OpenGL
#                    (each in a normal and a debug build)
#   make debug       only the debug renderers: AddressSanitizer and UBSan,
#                    and the Vulkan validation layers in priv/guiltty_vk-dbg
#   make width-table regenerate the Unicode width table from glibc
#   make icons       regenerate the icons from priv/icons/logo.svg

ERTS_INCLUDE_DIR ?= $(shell erl -noshell -eval 'io:format("~s/erts-~s/include", [code:root_dir(), erlang:system_info(version)]), halt().')

CC ?= gcc
CFLAGS_C23 = -std=c23 -Wall -Wextra -Wpedantic -g
SANITIZE = -O1 -fsanitize=address,undefined -fno-omit-frame-pointer

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
	$(CC) $(CFLAGS_C23) -O2 -fPIC -shared -I$(ERTS_INCLUDE_DIR) -o $@ $< -lutil

$(RENDERER_GL): $(RENDERER_CORE) $(RENDERER_HEADERS) $(GL_SRC) $(GL_SHADERS)
	@mkdir -p $(PRIV)
	$(CC) $(CFLAGS_C23) -O2 $(RENDERER_CFLAGS) -o $@ $(RENDERER_CORE) $(GL_SRC) $(RENDERER_LIBS) -lm

debug: $(RENDERER_VK)-dbg $(RENDERER_GL)-dbg

$(RENDERER_GL)-dbg: $(RENDERER_CORE) $(RENDERER_HEADERS) $(GL_SRC) $(GL_SHADERS)
	@mkdir -p $(PRIV)
	$(CC) $(CFLAGS_C23) $(SANITIZE) $(RENDERER_CFLAGS) -o $@ $(RENDERER_CORE) $(GL_SRC) $(RENDERER_LIBS) -lm

$(VK_SHADER_DIR)/%.spv: $(VK_SHADER_DIR)/% $(VK_SHADER_DIR)/frame.glsl
	glslc --target-env=vulkan1.3 -O -o $@ $<

$(RENDERER_VK): $(RENDERER_CORE) $(RENDERER_HEADERS) $(VK_SRC) $(VK_SPV)
	@mkdir -p $(PRIV)
	$(CC) $(CFLAGS_C23) -O2 $(RENDERER_CFLAGS) $(VK_CFLAGS) -o $@ $(RENDERER_CORE) $(VK_SRC) $(RENDERER_LIBS) $(VK_LIBS) -lm

$(RENDERER_VK)-dbg: $(RENDERER_CORE) $(RENDERER_HEADERS) $(VK_SRC) $(VK_SPV)
	@mkdir -p $(PRIV)
	$(CC) $(CFLAGS_C23) $(SANITIZE) -DGUILTTY_VK_VALIDATION $(RENDERER_CFLAGS) $(VK_CFLAGS) -o $@ $(RENDERER_CORE) $(VK_SRC) $(RENDERER_LIBS) $(VK_LIBS) -lm

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

.PHONY: all debug clean width-table icons

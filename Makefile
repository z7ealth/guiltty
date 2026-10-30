# Built by elixir_make during `mix compile`. It exports ERTS_INCLUDE_DIR;
# the fallback lets you run `make` by hand too.
#
#   make             the PTY NIF and the OpenGL renderer (both builds)
#   make debug       only the renderer with AddressSanitizer and UBSan,
#                    priv/guiltty_gl-dbg
#   make width-table regenerate the Unicode width table from glibc

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

all: $(NIF) $(RENDERER_GL) $(RENDERER_GL)-dbg

$(NIF): c_src/pty_nif.c
	@mkdir -p $(PRIV)
	$(CC) $(CFLAGS_C23) -O2 -fPIC -shared -I$(ERTS_INCLUDE_DIR) -o $@ $< -lutil

$(RENDERER_GL): $(RENDERER_CORE) $(RENDERER_HEADERS) $(GL_SRC) $(GL_SHADERS)
	@mkdir -p $(PRIV)
	$(CC) $(CFLAGS_C23) -O2 $(RENDERER_CFLAGS) -o $@ $(RENDERER_CORE) $(GL_SRC) $(RENDERER_LIBS) -lm

debug: $(RENDERER_GL)-dbg

$(RENDERER_GL)-dbg: $(RENDERER_CORE) $(RENDERER_HEADERS) $(GL_SRC) $(GL_SHADERS)
	@mkdir -p $(PRIV)
	$(CC) $(CFLAGS_C23) $(SANITIZE) $(RENDERER_CFLAGS) -o $@ $(RENDERER_CORE) $(GL_SRC) $(RENDERER_LIBS) -lm

# The Unicode width table comes from glibc's wcwidth(3). It's checked in;
# rebuild it after a glibc upgrade.
WIDTH_TABLE = lib/guiltty/unicode/width_table.ex

width-table:
	$(CC) $(CFLAGS_C23) -o $(PRIV)/gen_width c_src/tools/gen_width.c
	$(PRIV)/gen_width > $(WIDTH_TABLE)
	rm -f $(PRIV)/gen_width
	mix format $(WIDTH_TABLE)

clean:
	rm -f $(NIF) $(RENDERER_GL) $(RENDERER_GL)-dbg

.PHONY: all debug clean width-table

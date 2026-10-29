# Built by elixir_make during `mix compile`. It exports ERTS_INCLUDE_DIR;
# the fallback lets you run `make` by hand too.

ERTS_INCLUDE_DIR ?= $(shell erl -noshell -eval 'io:format("~s/erts-~s/include", [code:root_dir(), erlang:system_info(version)]), halt().')

CC ?= gcc
CFLAGS_C23 = -std=c23 -Wall -Wextra -Wpedantic -g

PRIV = priv
NIF = $(PRIV)/pty_nif.so

all: $(NIF)

$(NIF): c_src/pty_nif.c
	@mkdir -p $(PRIV)
	$(CC) $(CFLAGS_C23) -O2 -fPIC -shared -I$(ERTS_INCLUDE_DIR) -o $@ $< -lutil

clean:
	rm -f $(NIF)

.PHONY: all clean

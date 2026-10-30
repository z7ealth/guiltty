# guiltty

A GPU terminal emulator in Elixir, with a little C: a PTY NIF and an
OpenGL renderer that runs as its own process.

## Run it

Needs Elixir 1.20, GCC 15+ and the SDL3, FreeType and fontconfig
development packages.

```sh
mix deps.get
mix guiltty        # development: a window; closing it ends everything
mix test
```

As a release, with tabs that survive closing the window:

```sh
MIX_ENV=prod mix release
_build/prod/rel/guiltty/bin/guiltty     # starts guiltty if needed, opens a window
```

Run `guiltty` again after closing the window and your tabs are still
there. Keys: Ctrl+Shift+T new tab, Ctrl+Shift+W close it, Ctrl+PgUp/PgDn
switch. Copy `priv/config.example.exs` to
`~/.config/guiltty/config.exs` to change the theme, font and keys; saving
it applies them to the open window.

## Learn how it works

- `book/` explains every part, with diagrams. Start at `book/index.org`.
- `DEVLOG.md` is what happened along the way.
- `AGENTS.md` has the rules for working on the code.

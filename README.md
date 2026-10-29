# guiltty

A GPU terminal emulator in Elixir, with a little C: a PTY NIF and an
OpenGL renderer that runs as its own process.

## Run it

Needs Elixir 1.20, GCC 15+ and the SDL3, FreeType and fontconfig
development packages.

```sh
mix deps.get
mix guiltty        # opens a window running bash
mix test
```

## Learn how it works

- `book/` explains every part, with diagrams. Start at `book/index.org`.
- `DEVLOG.md` is what happened along the way.
- `AGENTS.md` has the rules for working on the code.

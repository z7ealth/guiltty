# guiltty

A GPU terminal emulator in Elixir, with a little C: a PTY NIF and an
OpenGL renderer that runs as its own process.

## Run it

Needs Elixir 1.20, GCC 15+ and the SDL3, FreeType, fontconfig and
HarfBuzz development packages. Fonts come from fontconfig: install a CJK
font (`noto-sans-cjk-fonts` on openSUSE) to see Chinese and Japanese, and
an emoji font (Noto Color Emoji) for emoji.

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
there.

| Keys                          | Action                                   |
|-------------------------------|------------------------------------------|
| Ctrl+Shift+T, Ctrl+Shift+W    | new tab, close tab                       |
| Ctrl+PgUp, Ctrl+PgDn          | previous, next tab                       |
| Shift+PgUp, Shift+PgDn        | scroll back, forward (or the mouse wheel)|
| Ctrl+Shift+F                  | search; Enter older, Shift+Enter newer, Escape ends |
| select with the mouse         | copies to the primary selection          |
| Ctrl+Shift+C, Ctrl+Shift+V    | copy, paste (middle click pastes the selection) |
| Ctrl+=, Ctrl+-, Ctrl+0        | zoom in, out, reset                      |

Hold Shift to select in programs that use the mouse (vim, htop). Copy
`priv/config.example.exs` to
`~/.config/guiltty/config.exs` to change the theme, font and keys; saving
it applies them to the open window.

## Learn how it works

- `book/` explains every part, with diagrams. Start at `book/index.org`.
- `DEVLOG.md` is what happened along the way.
- `AGENTS.md` has the rules for working on the code.

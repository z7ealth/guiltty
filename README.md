<p align="center">
  <img src="priv/icons/guiltty-lockup-card.svg" alt="guiltty" width="320">
</p>

# guiltty

A GPU terminal emulator in Elixir, with a little C: a PTY NIF and an
OpenGL renderer that runs as its own process.

## Install it

```sh
./install.sh               # builds and installs into ~/.local (no root)
guiltty                    # or find guiltty in your applications menu
./install.sh --uninstall   # removes it; your config stays
```

Run `./install.sh` again to update. It needs Elixir, GCC and the
development files below.

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

As a release (what `./install.sh` installs):

```sh
MIX_ENV=prod mix release
_build/prod/rel/guiltty/bin/guiltty     # starts guiltty if needed, opens a window
```

Closing the window ends guiltty and its tabs. With `on_close: :detach`
in the config they keep running instead, and the next `guiltty` opens
them where you left them.

| Keys                          | Action                                   |
|-------------------------------|------------------------------------------|
| Ctrl+Shift+T, Ctrl+Shift+W    | new tab, close tab                       |
| Ctrl+PgUp, Ctrl+PgDn          | previous, next tab                       |
| Shift+PgUp, Shift+PgDn        | scroll back, forward (or the mouse wheel)|
| Ctrl+Shift+F                  | search; Enter older, Shift+Enter newer, Escape ends |
| select with the mouse         | copies to the primary selection          |
| Ctrl+Shift+C, Ctrl+Shift+V    | copy, paste (middle click pastes the selection) |
| Ctrl+=, Ctrl+-, Ctrl+0        | zoom in, out, reset                      |
| Ctrl+,                        | open the config file in your editor      |
| Ctrl+Shift+/                  | the cheatsheet: every key, on one page   |

Hold Shift to select in programs that use the mouse (vim, htop). Copy
`priv/config.example.exs` to
`~/.config/guiltty/config.exs` to change the theme, font and keys; saving
it applies them to the open window.

## Learn how it works

- `book/` explains every part, with diagrams. Start at `book/index.org`.
- `DEVLOG.md` is what happened along the way.
- `AGENTS.md` has the rules for working on the code.

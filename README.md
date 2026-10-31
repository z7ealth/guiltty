<p align="center">
  <img src="priv/icons/guiltty-lockup-card.svg" alt="guiltty" width="320">
</p>

# guiltty

A GPU terminal emulator in Elixir and C. Elixir holds the behavior: the
parser, the screen, tabs, windows, config. C does the syscalls and the
pixels: a PTY NIF, a renderer (Vulkan, or OpenGL) that runs as its own
process, and the small `guiltty` command.

Linux only. Tried on openSUSE Tumbleweed, X11 and an AMD GPU; Wayland,
Intel, NVIDIA and other distributions should work but haven't been
tried.

It isn't fast at heavy output: a big `cat` goes by at about 3 to 4 MB/s
(book chapter 22).

## Install

guiltty is built from source on your machine, so installing it needs
Elixir and a C toolchain. The installed copy carries its own Erlang
runtime: once it's installed, it runs without Elixir.

### 1. What to install first

| What                                       | Why                                      |
|--------------------------------------------|------------------------------------------|
| Elixir 1.20 and Erlang/OTP (developed on 29) | building guiltty and its release       |
| GCC 15 or newer, make, pkg-config          | the C is C23 and uses `#embed` (GCC 15+) |
| SDL3 (development files)                   | the window, keyboard and mouse           |
| FreeType, fontconfig, HarfBuzz (dev files) | finding fonts, drawing and shaping text  |
| Vulkan loader and headers (dev files)      | the Vulkan renderer                      |
| glslc (from shaderc)                       | compiles the Vulkan shaders to SPIR-V    |

Your distribution's packages work if they're recent enough; for Elixir
and Erlang, a version manager such as [asdf](https://asdf-vm.com) gets
you exact versions. `elixir --version` should say Elixir 1.20.

On these distributions, one command installs it all. Only openSUSE has
been tried; the other package names come from each distribution's
package listings.

**openSUSE Tumbleweed**

```sh
sudo zypper install gcc make pkg-config SDL3-devel freetype2-devel \
  fontconfig-devel harfbuzz-devel vulkan-devel shaderc elixir erlang-epmd
```

**Fedora 45 or newer**

```sh
sudo dnf install gcc make pkgconf-pkg-config SDL3-devel freetype-devel \
  fontconfig-devel harfbuzz-devel vulkan-loader-devel vulkan-headers glslc elixir
```

Fedora 43 and 44 have everything but Elixir 1.20: leave out `elixir` and
get Elixir and Erlang from asdf.

**Ubuntu 26.04 LTS or newer**

```sh
sudo apt install build-essential pkg-config libsdl3-dev libfreetype-dev \
  libfontconfig-dev libharfbuzz-dev libvulkan-dev glslc
```

Ubuntu 26.04's Elixir is 1.18, too old: get Elixir 1.20 and Erlang from
asdf. From Ubuntu 26.10 on, add `elixir erlang-dev` to the command
instead. Older Ubuntus have neither SDL3 nor GCC 15.

**Arch Linux**

```sh
sudo pacman -S --needed base-devel sdl3 freetype2 fontconfig harfbuzz \
  vulkan-icd-loader vulkan-headers shaderc elixir
```

guiltty itself is developed on Elixir 1.20.4 with Erlang/OTP 29, both
from asdf; a distribution's Elixir 1.20 may come with an older Erlang,
which should work but hasn't been tried.

guiltty also needs a GPU driver with OpenGL 3.3, which almost any desktop
from the last decade has. For Vulkan it needs a Vulkan 1.3 driver (for
AMD and Intel GPUs, Mesa's; only AMD has been tried).
Without one, guiltty draws with OpenGL.

Fonts come from fontconfig. guiltty looks best with a Nerd Font (for
prompt icons), Noto Color Emoji (for emoji) and a CJK font such as Noto
Sans CJK, for Chinese and Japanese.

### 2. guiltty

```sh
git clone https://github.com/z7ealth/guiltty.git
cd guiltty
./install.sh
```

That checks for the tools above, builds a release and installs it into
`~/.local` (no root needed):

| Where                                             | What            |
|---------------------------------------------------|-----------------|
| `~/.local/lib/guiltty/`                           | the release     |
| `~/.local/bin/guiltty`                            | the command     |
| `~/.local/share/applications/guiltty.desktop`     | the menu entry  |
| `~/.local/share/icons/hicolor/*/apps/guiltty.png` | the icon        |

Then run `guiltty`, or find it in your applications menu. If your shell
says `guiltty: command not found`, add `~/.local/bin` to your `PATH`.

- **Update:** `git pull && ./install.sh`. If guiltty is running, the
  script asks before stopping it, since that closes its tabs (`--yes`
  skips the question).
- **Uninstall:** `./install.sh --uninstall`. Your config stays.
- **Somewhere else:** `PREFIX=/opt/guiltty ./install.sh`.

## Use it

Every window has its own tabs: `guiltty` (or Ctrl+Shift+N) opens another
window, and closing one never touches the others. Closing a window ends its
tabs, except the ones you lock with Ctrl+Shift+L (they show a 🔒): those
keep running, and the next `guiltty` brings that window back with them.
guiltty stops after its last window.

| Keys                          | Action                                   |
|-------------------------------|------------------------------------------|
| Ctrl+Shift+N                  | new window, with its own tabs            |
| Ctrl+Shift+T, Ctrl+Shift+W    | new tab, close tab                       |
| Ctrl+PgUp, Ctrl+PgDn          | previous, next tab                       |
| Shift+PgUp, Shift+PgDn        | scroll back, forward (or the mouse wheel)|
| Ctrl+Shift+F                  | search; Enter older, Shift+Enter newer, Escape ends |
| select with the mouse         | copies to the primary selection          |
| Ctrl+Shift+C, Ctrl+Shift+V    | copy, paste (middle click pastes the selection) |
| Ctrl+=, Ctrl+-, Ctrl+0        | zoom in, out, reset                      |
| Ctrl+,                        | open the config file in your editor      |
| Ctrl+Shift+/                  | the cheatsheet: every key, on one page   |
| Ctrl+Shift+L                  | lock the tab: it outlives the window     |
| Ctrl+Shift+B                  | broadcast: type into all tabs in the group (ssh tabs) |

Hold Shift to select in programs that use the mouse (vim, htop).

## Configure it

The config file is `~/.config/guiltty/config.exs`. Ctrl+, creates it from
[priv/config.example.exs](priv/config.example.exs), which documents every
setting, and opens it in your editor. Saving applies most changes to the
open window. Mistakes show in red in the tab bar, so they don't go
unnoticed.

Among the settings: themes (Catppuccin, Dracula, Gruvbox, Solarized,
Tomorrow Night, or your own colors), font and size, cursor, padding,
opacity, the tab bar at the bottom (the default) or top, ligatures, the shell,
scrollback, and every key.

**Vulkan or OpenGL.** guiltty draws with Vulkan 1.3. If Vulkan can't
start (an old GPU, no driver), it switches to OpenGL by itself and says so
in the tab bar. With `renderer: :gl` in the config it always uses OpenGL,
starting with the next window.

## Hack on it

```sh
mix deps.get
mix guiltty        # a window from the source tree; closing it ends everything
mix test
iex -S mix         # the same, with an iex shell alongside
```

`mix compile` also builds the C (the NIF and both renderers, each in a
normal and a debug build). To try a release without installing it:

```sh
MIX_ENV=prod mix release
_build/prod/rel/guiltty/lib/guiltty-*/priv/guiltty   # starts guiltty if needed, opens a window
```

`make bench` measures throughput (book chapter 22). `AGENTS.md` lists
every command: debug builds, replaying the renderer, regenerating the
width table and the icons.

## Learn how it works

- `book/` explains every part, with diagrams. Start at `book/index.org`.
- `CHANGELOG.md` lists what each version added.
- `DEVLOG.md` is what happened along the way.
- `AGENTS.md` has the rules for working on the code.

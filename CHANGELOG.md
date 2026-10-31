# Changelog

What each version of guiltty added, newest first. Each version is one
milestone (MVP) of the build plan; `DEVLOG.md` tells how each one went,
and `book/` explains how it works.

Versions before 1.0 may change the config file. When they do, it's listed
under **Changed** or **Removed**, and guiltty reports old setting names in
the tab bar instead of ignoring them.

## Unreleased

### Fixed
- `guiltty` typed in a guiltty tab printed the release's usage instead of
  opening a window: the tab's `PATH` started with the release's own
  folders, which Erlang adds when it starts. They're left out now, so
  `guiltty` (and `erl`) mean the same in a tab as in any other terminal.

## 0.15.0 — 2026-10-31 — Client and server

### Changed
- `guiltty` (and the menu entry) is now a small program that asks the
  running guiltty for a window over a private socket, like `emacsclient`.
  With guiltty running, a new window takes about 0.1 s instead of 0.9 s;
  from cold, about 0.7 s instead of 1.3 s.
- Opening a window just as the last one closes always works: guiltty
  waits for the old one to finish instead of failing to start.
- `guiltty stop`, `pid` and `remote` work as before.
- The tab bar is at the bottom of the window by default. To keep it at the
  top, set `tab_bar: :top` in your config.

### Added
- A new window's first tab starts in the folder you ran `guiltty` in.
- A tab's shell gets its window's display (`DISPLAY` and the like), so GUI
  programs started from it open where that window is.

## 0.14.0 — 2026-10-31 — Performance

### Changed
- Programs that print many short lines (`seq`, logs, `cat` of a big file)
  show up about 3x faster: the screen lays such lines down together and
  scrolls once.
- guiltty starts about 100 ms sooner: the release loads each module the
  first time it's used instead of all of them at boot.
- The Vulkan renderer uploads only the rows that changed each frame, like
  the OpenGL one.

### Added
- `make bench`: throughput of the parser and grid alone, and of a real
  window (book chapter 22). `bench/time_to_window.sh` times how long a
  terminal takes to show its window, for hyperfine.

## 0.13.0 — 2026-10-30 — Multi window

### Added
- Several windows at once, each completely independent: its own tabs,
  locked tabs and broadcast group. Closing one never touches the others,
  and guiltty stops after the last.
- Ctrl+Shift+N opens a new window (`new_window` in `keys`).
- A window closed with locked tabs comes back as it was, with those tabs,
  the next time you run `guiltty`.

### Changed
- Running `guiltty` while guiltty is open opens another window (or brings
  back a closed one that kept locked tabs) instead of raising the open
  one.

## 0.12.4 — 2026-10-30 — Security

### Changed
- guiltty's background node now listens on 127.0.0.1 only, is named
  `guiltty@127.0.0.1`, and takes its cookie from `~/.erlang.cookie`
  instead of the command line, where every user on the machine could read
  it. `install.sh` stops if that file can be read by others. Reinstall to
  get it: a guiltty still running from an older version keeps the old
  name, so stop it first (`install.sh` asks).
- `guiltty` opens a window on a running guiltty in about 0.8 s instead of
  2.5 s (it no longer looks up the machine's hostname).
- The C parts (the PTY NIF and both renderers) are built hardened:
  buffer-size checks in libc calls, stack protection, position-independent
  executables and read-only relocations. A bug now crashes cleanly
  instead of being exploitable.

### Fixed
- Two places in the renderer that relied on their callers to stay in
  bounds now check for themselves (block characters, ligatures), as the
  static analyzers asked.
- `guiltty` returns as soon as it has started guiltty, about two seconds
  sooner. Before, it waited for the window that was already opening, and
  failed with status 1 if that window was closed in the meantime
  (`hyperfine guiltty` did).
- The shell is signaled through a pidfd instead of its process id, so a
  late signal can never reach another process that got the same id (maybe
  another tab's shell).
- Two calls on the same terminal from different threads could race when
  one closed it; each terminal now has a lock.
- A program that asked the terminal questions without reading the
  answers could make them pile up until guiltty ran out of memory. At most
  64 KB of answers now wait; the rest are dropped.
- Window and tab titles set by programs can no longer show guiltty's own
  markers (🔒 📡 🏠 ⚠), so a server can't make its tab look locked or in
  the broadcast group. Bidi and other control characters are removed too.
- The renderer used the window's size without checking that SDL could
  tell it; if it couldn't (a window gone mid-change), the grid size came
  from garbage. It now keeps the grid it has.

## 0.11.0 — 2026-10-30 — Ligatures

### Added
- `CHANGELOG.md`.
- Ligatures: with a font that has them (JetBrains Mono, Fira Code),
  `->`, `!=`, `|>`, `=>`, `===` and the like are drawn as one symbol.
  On by default; `ligatures: false` turns them off.
- Complete install instructions in the README: what to install first,
  what each dependency is for, and the commands for openSUSE, Fedora,
  Ubuntu and Arch.

### Changed
- The renderer protocol is now version 9 (the ligatures option). Build
  guiltty and its renderers together, as `mix compile` and `install.sh`
  do.
- The tabs look cleaner: each shows only its title, with more room
  around it, and no numbers or separators between them. The active tab is
  no longer bold. Ctrl+Shift+1 to 9 still go to tabs 1 to 9.

### Fixed
- `./install.sh` on a fresh Elixir install: it now installs Hex and
  rebar3 itself. Before, `mix deps.get` stopped to ask for them, with its
  output hidden, and the install seemed to hang.

## 0.10.0 — 2026-10-30 — Vulkan

### Added
- A Vulkan 1.3 renderer, `guiltty_vk`, now the default. It draws the same
  picture as the OpenGL one, pixel for pixel.
- `renderer: :vulkan | :gl` setting (applies to the next window).
- Automatic fallback: if Vulkan can't start (no driver, no GPU that can
  show the window), guiltty draws with OpenGL and says so in the tab bar.
- The renderer can replay recorded port messages and save a screenshot
  (`GUILTTY_RECORD`, `--replay`, `--screenshot`), and a test checks that
  OpenGL and Vulkan draw the same pixels.
- Book chapter 19, on the Vulkan backend.

### Changed
- Building needs `glslc` (from shaderc) and the Vulkan development files.

## 0.9.0 — 2026-10-30 — Broadcast

### Added
- Broadcast (Ctrl+Shift+B): type once into every tab in the group. A tab
  joins only while it runs ssh or mosh-client. If a connection drops,
  typing stops going anywhere and the bar shows which tab was lost, so
  commands never land on your own machine by mistake.
- Local tabs can join on purpose with a second Ctrl+Shift+B; they're
  marked 🏠.
- `broadcast_programs` setting.

## 0.8.0 — 2026-10-30 — Lockable tabs

### Added
- Lock a tab with Ctrl+Shift+L (it shows a 🔒). Closing the window closes
  every other tab; locked tabs keep running, and the next window opens
  them where you left them.

### Removed
- The `on_close` setting from 0.7.0. Locking tabs replaces it.

### Fixed
- 🔒 and other emoji drew as plain monochrome glyphs when the main font
  had them. Emoji now look for a color emoji font first.

## 0.7.0 — 2026-10-30 — The installer

### Added
- `./install.sh`: builds a release and installs it into `~/.local`, with
  a `guiltty` command, a menu entry and icons. `--uninstall` removes it.
- The guiltty logo, as the app icon and the window icon.

### Changed
- Closing the window quits guiltty. Until then, tabs always kept running
  in the background. `on_close: :detach` brought the old behavior back.

## 0.6.1 — 2026-10-30 — Cheatsheet and fixes

### Added
- The cheatsheet (Ctrl+Shift+/): every key on one page, built from your
  config.
- `tab_bar: :bottom` puts the tab bar at the bottom.
- Config errors show in red in the tab bar, with the file and line, until
  the file loads again.
- Misspelled setting names are reported, with a suggestion when one is
  close.

### Fixed
- A selection stayed on screen after its text was gone (after `clear`).
- A broken config at startup kept the window from opening.

## 0.6.0 — 2026-10-30 — Flat tabs and more settings

### Added
- A flat tab bar with an accent line under the active tab.
- Ctrl+, opens the config file in your editor, creating it from the
  example first.
- Named themes: Catppuccin Mocha, Dracula, Gruvbox Dark, Solarized Dark,
  Tomorrow Night.
- Settings for cursor style and blink, window padding, size and opacity,
  the shell, copy-on-select, wheel lines and bold-is-bright.
- `working_directory`: new tabs start in the current tab's directory
  (`:inherit`), at home, or in a fixed path.
- Cursor shapes set by programs (DECSCUSR), and a hollow cursor when the
  window isn't focused.

## 0.5.1 — 2026-10-30 — Prompt fixes

### Fixed
- Box-drawing, block and shade characters are drawn by guiltty instead of
  the font, so lines meet with no gaps (powerlevel10k's prompt looked cut).
- Nerd Font icons get room to spill into the next cell instead of being
  clipped.

## 0.5.0 — 2026-10-30 — Daily driver

### Added
- Unicode: UTF-8, grapheme clusters, wide characters, fallback fonts,
  HarfBuzz shaping and color emoji.
- 10,000 rows of scrollback, and search (Ctrl+Shift+F).
- Mouse selection, copy and paste with the primary selection and the
  clipboard.
- Dead keys and input methods, zoom (Ctrl+=, Ctrl+-, Ctrl+0), and HiDPI
  screens.

## 0.4.0 — 2026-10-29 — The BEAM advantage

### Added
- Tabs (Ctrl+Shift+T, Ctrl+Shift+W, Ctrl+PgUp, Ctrl+PgDn).
- Crash-proof sessions: a crashed part restarts on its own, and the
  screen heals.
- Detach and reattach: closing the window leaves the shells running, and
  `guiltty` opens them again.
- A config file, `~/.config/guiltty/config.exs`, applied live on save
  (theme, font, keys).
- Backpressure from the shell to the screen: a flood of output never
  piles up in memory.

## 0.3.43 — 2026-10-29 — The vim fight

### Added
- What full-screen programs need: the alternate screen, scroll regions,
  saved cursors, insert and origin modes, and answers to terminal
  queries. vim, less, htop, btop and tmux work.
- Special keys (arrows, Home/End, F1-F12, and so on) in normal and
  application modes, with modifiers.
- Bracketed paste, mouse reporting and window titles.

## 0.2.1 — 2026-10-29

### Fixed
- guiltty runs your login shell instead of always running bash.
- The shell no longer inherits guiltty's release variables
  (`RELEASE_COOKIE` among them).

## 0.2.0 — 2026-10-29 — Color

### Added
- 16, 256 and 24-bit color, bold, underline, strikethrough and inverse.
- A full escape-sequence parser (Paul Williams' DEC state machine).
- A resizable window: the shell gets SIGWINCH.

## 0.1.0 — 2026-10-29 — First light

### Added
- The whole pipeline: a PTY NIF, a parser, the screen in Elixir, and an
  OpenGL renderer as its own process. ASCII only, 80x24.

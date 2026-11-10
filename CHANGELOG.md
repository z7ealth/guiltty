# Changelog

What each version of guiltty added, newest first. Each version is one
milestone (MVP) of the build plan; `DEVLOG.md` tells how each one went,
and `book/` explains how it works.

Versions before 1.0 may change the config file. When they do, it's listed
under **Changed** or **Removed**, and guiltty reports old setting names in
the tab bar instead of ignoring them.

## 0.23.2 — 2026-11-10 — A purple version

### Changed
- `guiltty version` prints "tty" in the logo's purple, on a terminal.
  Into a pipe, or with `NO_COLOR` set, it stays plain `guiltty 0.23.2`.

## 0.23.1 — 2026-11-10 — A square password lock

### Fixed
- The password lock is about square now, instead of tall and narrow.

## 0.23.0 — 2026-11-10 — The password lock

### Added
- While a program reads a password (`sudo`, `ssh`, `passwd`, `read -s`),
  a lock shows in place of the cursor, so you can tell guiltty is
  listening even though nothing you type appears. guiltty spots it the
  way Ghostty does: the program has turned echo off but kept line
  editing on. Turn it off with `cursor: [password_lock: false]`.

### Changed
- The renderer protocol is version 14. A renderer from an older guiltty
  won't start with this one: install both together, as `./install.sh`
  does.

## 0.22.2 — 2026-11-10 — The laptop AI key, and more themes

### Added
- Five more themes: `nord`, `tokyo-night`, `one-dark`, `catppuccin-latte`
  (the first light one) and `guiltty`, guiltty's own: the icon's lavender
  on near-black, with lavender for the cursor, the tab accent and the
  focused pane's border. `theme: "guiltty"`.
- The AI key on newer laptops opens the AI tool, like Ctrl+Shift+Space.
  The key sends Super+Shift+F23, which is now in the default `ai:` list.
- Key names in `keys:` can use `super` (the Windows key) and the
  function keys F13 to F24.

### Changed
- The default theme is `guiltty` now, not Tomorrow Night. To keep the old
  look, set `theme: "tomorrow-night"`. A theme given as a list of colors
  with no `name:` starts from `guiltty` too.
- A key with Super held no longer triggers a binding that doesn't name
  `super`: Super+Ctrl+Shift+T doesn't open a tab. A config that sets
  `ai:` under `keys:` keeps its own keys; add `"super+shift+f23"` to it
  for the laptop key.

## 0.22.1 — 2026-11-09 — Select all

### Added
- Ctrl+Shift+A selects everything, as Select All does in an editor: the
  scrollback and the screen, down to the last row with text (on vim's or
  htop's screen, that screen alone). Like a mouse selection it goes to the
  primary selection, as `copy_on_select` says; Ctrl+Shift+C copies it.
  `select_all` in `keys:`.
- `space` names the space bar in `keys:` (`"ctrl+shift+space"`).

### Changed
- The AI key is Ctrl+Shift+Space now, and Ctrl+Shift+A selects all. A
  config that sets `ai:` under `keys:` keeps its own key.

## 0.22.0 — 2026-11-09 — Clickable URLs

### Added
- Ctrl+click opens URLs in plain text, like the address `mix phx.server`
  prints, not only links a program marked (OSC 8). Hold Ctrl and move the
  mouse over one to see it underlined. It finds http, https, mailto and file
  URLs, even when one wraps onto the next row, and leaves out punctuation
  that ends the sentence. `link_url: false` turns it off.

## 0.21.0 — 2026-11-09 — The AI key

### Added
- An AI key: set `ai: [command: "your-ai-tool"]`, and Ctrl+Shift+A (`ai` in `keys:`)
  opens that tool in a pane beside you, and goes back and forth. `position: :down`
  or `:tab` puts it elsewhere. What's selected goes to its prompt, without Enter, and
  nothing else on your screen does. Guiltty only starts the program: no API keys
  or accounts here, and any command-line tool works.

## 0.20.1 — 2026-11-09 — Right click

### Added
- Right click with text selected copies it to the clipboard and pastes it at the
  prompt under the pointer. Hold Shift to do this in a program that uses the mouse.

## 0.20.0 — 2026-11-09 — A terminal you can rely on

### Added
- Long lines rewrap when the window or a pane changes width, in the scrollback
  too, and the cursor stays on the same character (reflow).
- Left Alt works as Meta: Alt+B is `ESC b`, so readline, Emacs and the like move
  by words. Right Alt stays AltGr. Ctrl+Space, Ctrl+[, Ctrl+\\, Ctrl+], Ctrl+^,
  Ctrl+_ and the Ctrl+digit row send what they do in xterm.
- The Kitty keyboard protocol: programs like Neovim and Helix can tell Ctrl+I
  from Tab and Shift+Enter from Enter, and see key releases. Flags 1, 2 and 8;
  not 4 and 16.
- Copying in a program over ssh reaches your clipboard (OSC 52), from the
  focused pane. Programs can never read it. `clipboard_write: false` turns it off.
- Hyperlinks (OSC 8): `ls --hyperlink` and the like. Ctrl+click opens http, https,
  mailto and file links, and the status says where it went.
- Prompts (OSC 133): Ctrl+Shift+Z and Ctrl+Shift+X jump to the previous and next
  prompt, for shells set up to mark them (`prev_prompt`, `next_prompt`).
- A new tab starts where a program says it is (OSC 7), when that's on this machine.
- Programs can set and ask for colors (OSC 4, 10, 11, 12 and their resets), per
  pane, so `vim` and others can tell a dark background from a light one.
- Focus events (mode 1004), for `vim` and `tmux`. Synchronized output (mode 2026):
  no half-drawn frames in programs that use it. Overline (SGR 53).
- Custom tab stops, back tab, reverse video (the visible bell), the title stack,
  left and right margins, rectangle fill, copy, erase and restyle, selective
  erase, G2 and G3 character sets, ISO Latin-1 as a character set, more mouse encodings (9, 1005, 1015, 1016),
  LNM and reverse wrap (45, 1045).
- Programs can ask what guiltty supports: DECRQM, DECRQSS, DECREQTPARM, XTGETTCAP,
  DA3 and the rest of the status reports.
- `screen_reports: true` answers DECRQCRA and the title reports, for test suites.
  It stays off: it lets a program read your screen, even over ssh.
- A tab that runs out of memory (2 GB) is restarted alone, instead of taking
  every tab with the VM.

### Changed
- guiltty now reports itself as a VT520, not a VT220 (DA1 and DA2), since it
  does what those are expected to do.
- The wheel on the alternate screen sends arrow keys unless a program turns that
  off (mode 1007).
- The renderer protocol is now version 13. Build guiltty and its renderers
  together, as `mix compile` and `install.sh` do.

### Fixed
- C1 controls in UTF-8 (U+0080 to U+009F) printed as text. They now act as what
  they stand for, as in xterm.
- An underline color (`58;5;1`) also turned on blink and bold.
- Making a window shorter threw away the rows it pushed off the top. They now go
  to the scrollback.
- REP and NEL did the wrong thing at the left and right margins.

## 0.19.1 — 2026-11-06 — Borders and layouts

### Added
- The border between split panes can be styled: `pane_border: [style:
  :solid | :dashed | :double | :none, thickness: :thin | :thick]`, and
  colored in the theme with `pane_border` and `pane_border_active` (the
  border along the focused pane).
- `plus` names the + key in `keys:` (`"ctrl+plus"`), for layouts where +
  has a key of its own.

### Changed
- Default keys that work on US and Latin American layouts alike: the
  cheatsheet is also on Ctrl+Shift+H (Ctrl+Shift+/ stays), and zoom in is
  also on Ctrl and the + key (`ctrl+plus`). On a Latin American layout
  neither default could be pressed before: a punctuation key is named by
  what it types without Shift, and no key there types / or = unshifted.
- Moving between panes is Ctrl+Shift+arrows, and resizing them
  Alt+Shift+arrows: desktops (XFCE, GNOME) take Ctrl+Alt+arrows for
  workspaces and Ctrl+Shift+Alt+arrows for moving windows.

## 0.19.0 — 2026-11-06 — Split panes

### Added
- Split panes: several shells in one tab, side by side. Ctrl+Shift+O
  splits the focused pane right, Ctrl+Shift+E down; Ctrl+Shift+arrows (or a
  click) moves the focus; Alt+Shift+arrows moves the separator
  nearest the focused pane. Each pane is a whole terminal, with its own
  scrollback, search, selection and images. New keys in `keys:`
  (`split_right`, `split_down`, `focus_left`/`right`/`up`/`down`,
  `resize_left`/`right`/`up`/`down`), and a Panes card on the cheatsheet.

### Changed
- Ctrl+Shift+W (`close_tab`) closes the focused pane; the tab closes with
  its last pane. In a tab of one pane, nothing changes.
- Ctrl+Shift+B puts every pane of the tab in the broadcast group (or
  takes them out) at once: split, ssh in each pane, and type into all of
  them.

## 0.18.2 — 2026-11-06 — One-line install

### Added
- A one-line install: `curl -fsSL https://raw.githubusercontent.com/z7ealth/guiltty/master/get.sh | sh`.
  It finds your distribution (openSUSE, Fedora, Ubuntu/Debian, Arch),
  installs the missing build packages after asking, checks Elixir, and
  builds the latest release into `~/.local`. Run it again to update.

## 0.18.1 — 2026-11-05 — kitten icat

### Fixed
- `kitten icat` shows big pictures. It repeats `a=T` on every chunk of
  an image, and guiltty took each chunk for a new image, so nothing
  showed; now, as in Kitty, it's the same image.

## 0.18.0 — 2026-11-05 — Images

### Added
- Images: programs that use the Kitty graphics protocol show pictures in
  guiltty. yazi previews images, `kitten icat`, `chafa` and `timg` work.
  Raw RGB, RGBA and PNG, zlib-compressed or not, sent in chunks; images
  scroll with the text and can be scrolled back to. Not supported:
  sixel, animation, Unicode placeholders, and images read from a file
  path (`t=f`), which a remote program could use to read your files.
- Programs can ask how big a cell is in pixels: guiltty sets the pixel
  size on the terminal (`TIOCGWINSZ`'s `ws_xpixel`/`ws_ypixel`) and answers
  `CSI 14 t`, `CSI 16 t` and `CSI 18 t`.
- guiltty answers `CSI > q` (XTVERSION) with its name and version.
- Ctrl+, opens the config in a new tab running `$VISUAL` (or `$EDITOR`),
  when one is set in guiltty's environment; the tab closes when you quit
  the editor. Without one it opens in the desktop's app, as before.

### Changed
- Building guiltty now needs libpng's development files
  (`libpng16-devel` on openSUSE, `libpng-dev` on Ubuntu; see the README).

## 0.17.1 — 2026-11-05 — Broadcast warning

### Fixed
- "⚠ broadcast paused" now shows in the bar even while there's a config
  error. Before, the config error hid it, and keys seemed to go nowhere
  for no reason.

## 0.17.0 — 2026-11-02 — Faster text

### Changed
- Text that isn't plain ASCII (accents, symbols, CJK, emoji) prints about
  twice as fast: `cat` of a log with a little of each on every line went
  from 3.8 to 7.6 MB/s. Letters that can't combine with their neighbours
  are now turned into cells by a small piece of C inside guiltty; how
  anything shows on screen is unchanged.
- Full-screen programs redrawing (htop, vim scrolling) are processed
  about 50% faster, and plain scrolling output about 10%.

## 0.16.1 — 2026-11-01 — Tab styles

### Added
- Tab styles: `tab_style: :powerline` (colored blocks joined by arrows),
  `:rounded` (pills), `:minimal` (no bar, a line under the active tab) or
  `:separators` (thin bars between titles). `:flat`, today's look, stays
  the default.
- The tab bar's colors can be set in the theme: `tab_bar`, `tab_text`,
  `tab_active`, `tab_active_text` and `tab_accent`. Any left out are
  worked out from the theme, as before.

### Changed
- Powerline arrows and half circles (U+E0B0, U+E0B2, U+E0B4, U+E0B6) in
  prompts are drawn by guiltty, like box drawing: they meet the blocks
  next to them exactly, and show even without a Nerd Font.
- The renderer protocol is now version 10. Build guiltty and its
  renderers together, as `mix compile` and `install.sh` do.

## 0.16.0 — 2026-11-01 — Tab comforts

### Added
- Closing a tab that's running a program (vim, ssh, a build) asks first:
  the tab bar says what's running, and pressing Ctrl+Shift+W again closes
  it. A tab waiting at its prompt closes at once, as before.
- A tab you're not looking at shows ● when it prints something and 🔔
  when it rings the bell, until you switch to it.
- Ctrl+Shift+PgUp and Ctrl+Shift+PgDn move the tab left and right
  (`move_tab_left`, `move_tab_right` in `keys`).
- Ctrl+Shift+R renames the tab: type a name, Enter. The name stays even
  when the program changes its title; an empty name gives the title back
  (`rename_tab`).
- Ctrl+Shift+K clears the tab's scrollback; the screen stays
  (`clear_scrollback`).
- `GUILTTY_RENDERER=gl` (or `vulkan`) picks the renderer for a run,
  whatever the config says. Set it when guiltty starts:
  `guiltty stop`, then `GUILTTY_RENDERER=gl guiltty`.
- guiltty is under the MIT License (`LICENSE`).

### Changed
- guiltty now builds with Elixir 1.18 or newer on Erlang/OTP 26 or newer
  (tried: 1.18.4 and 1.19.7 on OTP 26, 1.19.7 on OTP 28, 1.20.4 on OTP
  29). It asked for Elixir 1.20 before, without needing anything from it.

### Fixed
- `./install.sh` run from a guiltty tab stopped halfway: stopping guiltty
  closed the tab, and the script with it, before the new version was
  installed. Now it finishes (its output goes to
  `~/.local/state/guiltty/install.log`) and opens guiltty again. The old
  and new versions are also swapped so that one is always installed.
- Building after switching Erlang versions (with asdf, say) rebuilds the
  PTY NIF for the new one. Before, the old build was kept, and the new
  Erlang refused to load it ("NIF library needs erts-... or newer"),
  in the build and in the installed copy.
- On Erlang/OTP 26, a request to the `guiltty` socket with a line that's
  too long is refused at once with "line too long", as on later OTPs,
  instead of after a 2 s wait.

## 0.15.3 — 2026-10-31

### Changed
- The README says what guiltty has been tried on and how fast it is at
  heavy output.

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
  show up about 3x faster (`make bench`, a real window: 1.2 to 4.0 MB/s):
  the screen lays such lines down together and scrolls once.
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
- Several windows at once, each with its own tabs, locked tabs and
  broadcast group. Closing one never touches the others,
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
- Ligatures: with a font that has them (tried with JetBrains Mono),
  `->`, `!=`, `|>`, `=>`, `===` and the like are drawn as one symbol.
  On by default; `ligatures: false` turns them off.
- Install instructions in the README: what to install first, what each
  dependency is for, and the commands for openSUSE, Fedora, Ubuntu and
  Arch (only openSUSE's have been tried).

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
- A Vulkan 1.3 renderer, `guiltty_vk`, now the default. On the recorded
  test session it draws the same picture as the OpenGL one: no pixel
  differs.
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

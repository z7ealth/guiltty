# guiltty devlog

## 2026-10-29 — Prologue: pty_lab

_Draft: agent, awaiting user_

**Tried.** Built `lab/pty_lab`, a small C program that opens a PTY with
`openpty`, forks, puts bash on the slave side and prints every byte bash sends
back. It runs interactively or from a script (`./pty_lab 'echo hi' exit`).

**Broke.** The plan expects `\x1b[?2004h` around the prompt, but it never
showed up. It turns out readline on this openSUSE install has
`enable-bracketed-paste off`. With `INPUTRC` pointing at a file that turns it
on, `\x1b[?2004h` appears before every prompt and `\x1b[?2004l` right after
Enter. Also, the openSUSE prompt sets the title with OSC 2 and OSC 1 wrapped in
`\x1b7`/`\x1b8`, not OSC 0.

**Clicked.** The master never returns 0 at the end; on Linux it fails with
`EIO` once the last slave fd closes. With `--keep-slave` the parent keeps
its copy open, bash exits, and the master just goes quiet.

### Prologue questions (draft answers, confirm or correct)

1. **Why must `setsid()` come before `TIOCSCTTY`?** `TIOCSCTTY` only works for
   a session leader that has no controlling terminal yet (`ioctl_tty(2)`).
   After `fork` the child is still in our session and isn't its leader, so the
   ioctl fails with `EPERM`. `setsid()` makes it the leader of a fresh session
   with no terminal, and then it can claim the slave.
2. **What are `\x1b]0;…\x07` and `\x1b[?2004h`?** The first is an OSC
   ("operating system command") 0: set the window and icon title, ended by BEL.
   Here the prompt uses OSC 2 (title) and OSC 1 (icon name) instead.
   `\x1b[?2004h` turns on bracketed paste: the terminal should wrap pasted text
   in `\x1b[200~`…`\x1b[201~` so the shell can tell pasting from typing.
   `\x1b[?2004l` turns it off before the command runs.
3. **Why does `echo hi` come back before its output?** The terminal side
   echoes input the moment it arrives, long before Enter runs anything. In
   canonical mode the kernel's line discipline does it (the `ECHO` flag);
   under readline, bash switches the kernel echo off and echoes the keys
   itself. Either way the echo is written to the master first, and `hi` only
   exists once bash has run the command.
4. **What happens if the parent keeps its slave fd?** The master only sees
   the end (`EIO`) when *every* slave fd is closed. If the parent still holds
   one, bash can exit and the master just goes quiet forever: no EOF and no
   `POLLHUP`. You'd leak a zombie bash and a window that never closes.

### Later

- The NIF should resolve bash's path before forking and call `execve`, since
  `execvp` isn't on the async-signal-safe list.

## 2026-10-29 — MVP 1, steps 1 and 2: PTY NIF, parser v0, screen

_Draft: agent, awaiting user_

**Tried.** Moved pty_lab into `c_src/pty_nif.c`: a NIF resource holds the
master fd and the child pid, and `enif_select` replaces the poll loop. On top
of it, the session: `Pty`, `Screen` and `Parser` under a `rest_for_one`
supervisor, with a pure `Guiltty.Parser` (v0: skip escapes) and
`Guiltty.Grid` (80x24, scroll, pending wrap). `Guiltty.Session.dump(:main)`
prints the screen in iex.

**Broke.** The first run logged `{:error, :echild}` when bash exited. The
BEAM ignores SIGCHLD, so the kernel reaps our children itself and throws
away their exit status. `wait/1` now returns `:gone` for that case, and the
destructor never signals a pid it hasn't just seen alive, since a reaped
pid can be reused.

Elixir 1.20 wants a pin (`^n`) on variables used in binary sizes.

**Clicked.** Exit handling needed no code: the Pty is `significant`, so when
it stops after EOF its supervisor shuts down, and so does the application.

### Later

- Use `pidfd_open` so signalling the child can never hit a reused pid.
- The ignored SIGCHLD means we never learn bash's exit status. Fine for now.

## 2026-10-29 — MVP 1, steps 3 to 7: first light

_Draft: agent, awaiting user_

**Tried.** The renderer: a separate C program with a core (SDL3 window,
port protocol, FreeType atlas) and an OpenGL 3.3 backend behind a struct of
function pointers. The whole grid is one instanced draw call; shaders are
baked in with `#embed`. `Guiltty.Window` runs it as a port with
`{:packet, 4}`, checks the hello's protocol version, sends the setup and
forwards screen updates. Keys come back as TEXT and KEY messages and
`Guiltty.Keymap` turns them into bytes. `mix guiltty` opens a window.

**Broke.**
- `[[nodiscard]]` can't go on function-pointer struct members; GCC warns
  and ignores it.
- Under SDL's offscreen driver, LeakSanitizer reports 128 bytes from an
  unloaded library (Mesa's software EGL). The headless tests run with
  `detect_leaks=0`; on X11 the debug renderer exits with no reports at all.
- A test raced the handshake and sent its bad message before the setup.
  Window now has a `ready` flag, and a renderer whose stdin closes during
  the handshake exits quietly.

**Clicked.** The first frame drew correctly on the first try. And because
the Screen sends every row to a new subscriber, `kill -9` on the renderer
already brings the window back with its contents. That's an MVP 4 feature,
free.

Checked by hand with real X11 key events (XTest): `ls`, `echo`, `cat`,
Backspace, Tab, Ctrl+C on `sleep 100`, Ctrl+D, scrolling with `seq 1 30`,
`exit` closing the window, and closing the window ending bash, with no
leftover processes.

### Later

- The cursor is always drawn, even while a program would hide it (DECTCEM,
  MVP 2).
- The window isn't resizable yet (MVP 2).
- Font and size are fixed (Source Code Pro via fontconfig, 18 px).

## 2026-10-29 — Killing things from Observer

_Draft: agent, awaiting user_

**Broke.** Killing the session supervisor from Observer closed the window
and, in a release, stopped the VM. The old Pty traps exits, so it was still
in `terminate/2` (waiting up to a second for bash) when the root supervisor
restarted the session; the new Pty found `{:main, :pty}` taken
(`already_started`), the restart failed and the root supervisor gave up.
Elixir hides those supervisor reports by default, so it looked like a
silent shutdown.

Also found: after the Screen restarted, the Window stayed subscribed to
nobody and stopped updating. And killing the Registry stopped the app.

**Fixed.** The Pty's `terminate/2` returns at once and a helper process
waits for bash. `Session.start_named/3` waits for a dying previous owner of
a name before registering. The Window monitors the Screen and subscribes
again. The root supervisor is now `rest_for_one`, with the Registry first.
Every kill now recovers; restarting the session also restarts the Window,
so the window closes and reopens.

**Clicked.** To see why a supervisor gave up, remove the logger's primary
filters (`:logger.remove_primary_filter/1`) and the hidden supervisor
reports show up.

## 2026-10-29 — MVP 2: Color

_Draft: agent, awaiting user_

**Tried.** Parser v1 (Paul Williams' DEC state machine, with colon
sub-parameters and caps on everything), a `Guiltty.Terminal` that gives the
commands meaning, and a grid of 10-byte cells with a pen: SGR with 16, 256
and 24-bit colors, cursor movement, erase with back-color-erase, DECTCEM.
The renderer now gets the theme's 256-color palette in the setup message,
resolves each cell's colors itself, and draws in two passes (backgrounds,
then blended glyphs with fake bold, underline and strikethrough). The
window resizes: the renderer reports the new grid, the Screen resizes
without reflow, and `TIOCSWINSZ` makes the kernel send SIGWINCH. Protocol
version 2. `TERM=xterm-256color`, `COLORTERM=truecolor`.

**Broke.**
- Recording fixtures: `/etc/services` doesn't exist on openSUSE (it's in
  `/usr/etc`); `man ls` stops to ask which `ls` (use `man 1 ls`); keys typed
  before `less` is ready get lost and the recording hangs; and the
  recorder's `set -e` swallowed a nonzero exit silently.
- C23: `constexpr` allows one declarator per declaration.
- My live `git log` went through `less`, which draws at the bottom of the
  screen without the alternate screen (mode 1049, MVP 3).

**Clicked.** 13 recorded fixtures, and every snapshot matched pyte (an
independent Python VT emulator) cell by cell: text, cursor, bold,
underline, inverse and colors.

### Later

- MVP 3: alternate screen (1049), DECSC/DECRC, scroll regions, arrow keys.
- `less`'s `ESC[22;0;0t` (save the window title) is ignored.

## 2026-10-29 — Your shell, not bash

_Draft: agent, awaiting user_

**Broke.** guiltty always started bash, because `Pty` hard-coded
`System.find_executable("bash")`. Running zsh with powerlevel10k inside
also showed the prompt's Unicode as `?` (MVP 5's job), and `extop` failed
with "the name guiltty@hs-suse seems to be in use".

**Fixed.** The shell is now `$SHELL`, then the login shell from
`getent passwd`, then bash, then `/bin/sh`.

**Found.** The extop error is guiltty passing its release environment
(`RELEASE_NAME`, `RELEASE_NODE`, `RELEASE_COOKIE`, `BINDIR`, ...) to the
shell. Any Mix release started inside guiltty takes `RELEASE_NODE` from it
and collides; and every program can read the cookie.

**Fixed, too.** The shell no longer gets `RELEASE_*`, `BINDIR`, `ROOTDIR`,
`EMU` or `PROGNAME`. It matters even more for the cluster idea: a cluster
cookie opens every node, so it must never reach a shell. Left alone on
purpose: asdf's `ASDF_INSTALL_*`, `MIX_HOME` and `MIX_ARCHIVES`, which come
from the tool setup, not from guiltty.

## 2026-10-29 — MVP 3: The vim fight

_Draft: agent, awaiting user_

**Tried.** The alternate screen (47, 1047, 1049), DECSC/DECRC and CSI s/u,
scroll regions with IL/DL/SU/SD and a region-aware IND/RI, ICH/DCH, insert
mode, autowrap off, origin mode, REP, DEC line drawing (as ASCII
lookalikes until MVP 5), DECSTR, DECALN, and answers to DA1, DA2, DSR and
CPR. Keys: arrows, Home/End, Insert/Delete, PgUp/PgDn, F1-F12 and Shift+Tab
in normal and application modes, with modifiers. Paste (Ctrl+Shift+V,
Shift+Insert) with bracketed paste. Mouse reporting (1000/1002/1003, SGR
1006 and X10). Window titles from OSC 0/2. The renderer uploads only the
rows that changed. Protocol version 3.

**Broke.**
- My own test assumed 1049 homes the cursor; it doesn't, in xterm or here.
- In `--demo` mode the renderer was writing key events to stdout, which is
  the terminal you started it from (a bug since MVP 1).
- Comparing vim's output with pyte took a while: pyte has several gaps
  (no REP, no CSI s/u, ignores line drawing in UTF-8 mode, chokes on vim's
  probes), and its result changes depending on whether you read its screen
  in between. Bisecting byte by byte found each one.

**Clicked.** 19 fixtures, including two real vim sessions (split, insert,
Ctrl+D/E/Y scrolling); all match pyte where pyte implements the feature.
Live: vim with a split, scrolling one window, then `:qa!` brings the shell
screen back intact; same for less.

**Bosses.** With tmux, htop and btop installed: htop (meters, colors,
arrow keys in application mode, F5 tree view), tmux with three panes
(re-laid out on window resize, `[exited]` and the shell screen back), btop
(layout and truecolor; its graphs are braille, so `?` until MVP 5), and
extop (tabs, quit) all work live. A multi-line paste into zsh stays one
pasted block until Enter. bash needs readline's
`enable-bracketed-paste on`, which this openSUSE has off.

**Clicked, again.** tmux is the better reference: run a program in a
hidden 80x24 tmux pane, record its bytes with `pipe-pane`, and compare
guiltty's screen with `tmux capture-pane`. htop, vim, less, and tmux
itself running inside tmux all match, row for row and cursor included.

Flaky tests: the mouse test slept 300 ms for bash to turn mouse mode on;
it now waits until the Window has seen the mode. Waits for real shells and
renderers went from 2-3 s to 5 s. Even so, one unidentified failure showed
up about once in 100 full runs, and 151 runs of
`mix test --repeat-until-failure 150` passed. Next time it happens, the
first lines of its output say which test it was.

### Later

- Cursor shapes (DECSCUSR), focus events (1004), OSC 10/11 color queries.
- Tab stops (HTS/TBC) are fixed at 8.
- Alt+key isn't sent as ESC + key yet.

## 2026-10-29 — MVP 4: The BEAM advantage

_Draft: agent, awaiting user_

**Tried.** Tabs as sessions under a DynamicSupervisor, with `Guiltty.Tabs`
keeping order, titles and the active tab, and adopting running sessions
if it restarts. The Window became a view: closing it leaves the tabs
running, and the release's `guiltty` command (rel/env.sh.eex) starts the
node as a daemon if needed and opens a window on it. The chaos key
(Ctrl+Shift+K) kills the parser; the Pty notices the second attach, emits
telemetry and sends SIGWINCH (a new `winch/1` NIF), and the window's
border flashes. Backpressure end to end: Pty-to-Parser credits, a
synchronous Screen.apply, and the Window pulling one update per frame the
renderer reports. Config as code with live theme, font and keys.
Telemetry for reads, parses and frames. Protocol version 4.

**Broke.**
- `Task.async` links: a config that raised killed the Config process. A
  monitored, unlinked process fixed it; a test caught it.
- The flaky test from MVP 3 showed its name at last: a test called
  `Session.dump` while the session was restarting and the Screen wasn't
  registered yet. The `eventually` helpers now treat an exit as "not yet".
  31 repeated runs passed after that.
- My first chaos-key run opened vim on a swap-file prompt left by an
  earlier killed vim in my scratch directory.

**Clicked.** Live, through the release: three tabs, vim in one; the chaos
key flashes the halo and vim keeps working (`4Gdd` after it). Closing the
window and running `guiltty` again brings all three tabs back, vim as it
was. Editing the theme in config.exs recolors the open window in about a
second; a bigger font re-lays out the grid and vim follows. A 101 MB `cat`
in one tab took 6.3 s while another tab answered in 6 ms.

**Later the same day.** The chaos key went away after review: a key that
kills part of the terminal is a demo, not a daily-driver feature, and an
accidental press loses bytes in a plain shell. Killing a parser from
`guiltty remote` shows the same recovery (book chapter 12); the halo still
flashes on any parser restart.

**Not verified by me.** `kill -9` on the renderer: the safety checks in
my environment didn't allow it this time. It worked in MVP 1, and the new
Window takes the tabs back through the same path as reattaching.

## 2026-10-29 — MVP 5: Daily driver

_Draft: agent, awaiting user_

**Tried.** Unicode from end to end. The parser decodes UTF-8 and keeps a
character cut in half by a read until the next one. The grid splits text
into grapheme clusters, one per cell, two for wide ones (a cell grew from
10 to 14 bytes: a 32-bit glyph, 16 bits of attributes). Clusters with
several codepoints get ids, and ROWS messages carry their text to the
renderer. Widths come from glibc's own `wcwidth`, baked into a table by a
small C program, so guiltty agrees with `ls` and readline. The renderer
learned fallback fonts (fontconfig), shaping (HarfBuzz), color emoji, and
an atlas that fills as glyphs appear. On top of that: 10,000 rows of
scrollback, search, mouse selection with the X11 PRIMARY and CLIPBOARD,
dead keys and input-method preedit, zoom and HiDPI. Protocol version 5.

**Broke.**
- The first scrollback was a map from row number to row. On a flood of
  short lines it halved the speed. Profiling showed one map update and one
  allocation per line; now rows collect in a list and every 256 become
  one binary. Now 6.6 MB/s with scrollback; MVP 4's grid did 7.0 MB/s
  without any.
- The property test (random emoji, accents and flag halves, cut at random
  places) found that a flag split across reads paired the wrong regional
  indicators. The previous cluster is now segmented again together with
  all the new text, not just its first grapheme.
- A race: scroll back with the wheel, type at once, and the view stayed
  back, because the Window learns the scroll position only from the next
  update. It now also remembers that it moved the view itself.
- Several of my tests were wrong, not the code: `"é"` in source is the
  single codepoint U+00E9, not a cluster; "hello world" wraps at 10
  columns.

**Clicked.** A real `ls` recording of a folder named in Japanese, emoji,
flags and combining accents lines up column for column. On a private X
server with the US-International layout, real key events typed
`echo ¿Qué tal, señor?` with dead keys and bash printed it back. In the
same session, `seq 1 12000` was searched for `5000` almost 7,000 rows
back. A drag selection was copied with Ctrl+Shift+C and pasted back with
Ctrl+Shift+V, and a middle click pasted the PRIMARY selection. The
renderer runs clean under AddressSanitizer with leak checks on.

**Not verified.** A real HiDPI screen (Xvfb with SDL's scale override
doubled the font, as it should) and a CJK input method with a candidate
window (no IBus or Fcitx here). Kanji show as tofu until
`noto-sans-cjk-fonts` is installed. The week as your only terminal is
yours.

### Later

- Width of ZWJ sequences: wcswidth says 6 for 👨‍👩‍👧, guiltty draws 2.
  DEC mode 2027 (grapheme cluster width) would let programs agree.
- Reflow on resize, and joining wrapped rows when copying (selection puts
  a newline at every row end).
- OSC 52 (programs setting the clipboard), OSC 8 hyperlinks, URL detection
  (the MVP's stretch goal).
- Real bold and italic faces instead of the one-pixel smear.
- Box-drawing characters drawn by guiltty instead of the font, so lines
  meet without gaps. (Done on 2026-10-30.)

## 2026-10-30 — powerlevel10k, side by side with Ghostty

_Draft: agent, awaiting user_

**Tried.** Your prompt looked cut in guiltty and whole in Ghostty.
Recording what zsh prints showed why: `░▒▓` at the ends of each segment,
which the font draws as dot patterns, and three Nerd Font icons (openSUSE,
folder, clock) from the Private Use Area. wcwidth says those icons are
one column wide, but they're drawn wider, so guiltty cut them to one cell.
Now guiltty draws block elements, shades and the light and heavy box
lines itself (`sprites.c`), as Ghostty does. An icon followed by a space
can spill into that space. Any glyph from a fallback font that still
doesn't fit is shrunk instead of cut.

**Broke.**
- The first icon fix centered the icon across both cells, which closed
  the gap p10k leaves after the branch icon. Ghostty centers it on its own
  cell and only spills, so guiltty does too.
- Anti-aliased straight lines: a 2-pixel heavy line came out as one solid
  row between two half-transparent ones, and looked double. Straight lines
  are whole pixels now; only the rounded corners are anti-aliased.

**Clicked.** On a private X server, your real zsh with p10k in guiltty
looks like your Ghostty screenshot. A test page of boxes (light, heavy,
rounded), shades, quadrants and eighths joins with no gaps.

### Later

- Double box lines (═ ║ ╔) and dashed ones still come from the font;
  powerline separators (U+E0B0 to U+E0BF) too.

## 2026-10-30 — MVP 6: The window and the config

_Draft: agent, awaiting user_

**Tried.** You asked for Ghostty-style window controls, then chose
something smaller: keep KDE's title bar, keep keybinds instead of buttons,
and make the tabs look better. Tabs are now flat, with thin separators
and a blue accent line under the active one; long titles end in `…`.
Ctrl+, opens the config file in your editor, creating it from the example
first. The renderer does that with `SDL_OpenURL`, since it runs in your
desktop session. The config grew:
- named themes (Dracula, Gruvbox, Solarized, Catppuccin);
- cursor style and blink, which programs can change with DECSCUSR, plus a
  hollow cursor when the window isn't focused;
- window padding, starting size and background opacity;
- which shell to run, and new tabs starting in the current tab's
  directory (`/proc/<pid>/cwd`, then `chdir` in the NIF between fork and
  exec);
- copy-on-select, wheel lines, bold-is-bright.

Protocol version 6.

**Broke.** Little. The hollow cursor didn't show at first on the test X
server: with no window manager, the window never got a "focus lost"
event, because it never had focus. Moving focus away by hand showed it
works. My first book draft said plain vim changes the cursor shape out
of the box. It doesn't; neovim does.

**Clicked.** On a private X server: three tabs in the new style, tabs 2
and 3 opened in the directory tab 1 had `cd`'d into. Changing padding in
the config re-laid out the open window. A program's DECSCUSR turned the
cursor into an underline. A translucent window starts and draws (Xvfb has
no compositor, so the transparency itself is yours to see).

### Later

- OSC 7 (the shell reporting its directory), so `:inherit` follows a
  program that changes directory, not just the shell.
- Opacity changes without reopening the window.

## 2026-10-30 — The tab bar can go at the bottom

_Draft: agent, awaiting user_

`tab_bar: :bottom` in the config. The renderer keeps the bar as row 0
of its cell mirror and only changes where it draws it: the vertex shader
puts row 0 last and the other rows one up, and mouse clicks are mapped
back the same way. The accent line moves to the tab's top edge. Protocol
version 7: one more bit in the OPTIONS flags. Checked on a private X
server: the bar at the bottom, and a real click on tab 1 switched to it.
My first click script never found the window, so it sent nothing; the
bug was in the test, not guiltty.

## 2026-10-30 — Config errors show in the window

_Draft: agent, awaiting user_

A broken config used to show up only in the log, so a typo just looked
like guiltty ignoring you. Now the tab bar shows it in red, as one line
with the file and line (`⚠ config.exs:3: theme: unknown name "drakula"`),
until a save loads. Protocol version 8: the status message carries a
style.

**Broke.** The live test found what the unit tests didn't: start guiltty
with a broken config and the window never appeared. Config tells a new
subscriber about the error at once, the Window passed it to the renderer
before the setup, and the renderer exited on the unexpected first
message. Since the Window restarts when its renderer dies, it crash-looped.
Now nothing but the setup goes out before the handshake. A new test
reproduces it (it fails with the guard removed). Also, the line number
went missing for errors raised while the file runs, when the config sits
inside the current directory: stacktraces name it by a relative path.

## 2026-10-30 — Typos in the config, and settings without checks

_Draft: agent, awaiting user_

You asked whether new settings would warn too. Errors in general did, but
a misspelled name (`curser:`) was silently ignored, and a new setting
without a check would let any value through. Now unknown names are
reported, with a suggestion when one is close (`did you mean :cursor?`),
in every section, `keys:` included. A test feeds every setting a nonsense
value and expects an error; I checked that it fails for a setting added
without a check. Odd shapes like `font: :big` used to crash the Config
process; now they're an error message too. AGENTS.md has a "Config
options" rule: default, check, example line and book row, together.

## 2026-10-30 — A cheatsheet, NvChad-style

_Draft: agent, awaiting user_

Ctrl+Shift+/ shows every key on one page: cards in columns, colored
titles, keys on the right, built from the config so rebinding shows. The
nice part is that it needed no C and no protocol change. Elixir draws it
the way a program would, with cursor moves, palette colors and box
characters, through the same parser and terminal into a grid, and the
Window sends those rows instead of the tab's. Live on a private X server
in Catppuccin, opened and closed with real key presses. Two glitches
caught on the way: keys that didn't fit were cut ("Ctrl+Shift+T…" for
Ctrl+Shift+Tab), so now they get a line of their own; and on a narrow
window the help text ran into the title, so it's left out there.

Later the same day: you pointed out the sheet looked scattered, and it
was: cards went into whichever column was shortest. Now they sit in a
centered grid, rows balanced (6 cards with room for 5 per row are 3 + 3),
every card in a row as tall as the tallest, so tops and bottoms line up.
On an 80-column window the cards narrow a little so two fit side by side.

## 2026-10-30 — A selection that outlived its text

_Draft: agent, awaiting user_

You found it: select something, run `clear`, and the highlight stayed, a
white block over an empty screen. Selections hold row numbers so they
can follow their text through scrolling, and nothing ever dropped them.
Now the Screen remembers the selected text when the mouse lets go, and
drops the selection when the text under it changes, the way Alacritty and
Ghostty do. Comparing the text rather than the rows keeps a selection
that only scrolled. A test selects a line, scrolls it away with `seq`
(still selected), then runs `clear` (gone); it fails without the fix.

## 2026-10-30 — v0.7.0 begins: an installer

_Draft: agent, awaiting user_

v0.7.0 is "let's install and test". First piece: `./install.sh`, which
builds a release into `~/.local/lib/guiltty` (built next to the old one
and swapped in only if the build worked), adds a `guiltty` command, a
menu entry and the icon in every size, and `--uninstall` takes it all
away again. The renderer now names its window's class (`SDL_SetAppMetadata`)
so taskbars match it with the menu entry, and sets its own window icon,
from a BMP because SDL3 reads nothing else. A placeholder logo (`>_`)
waits for the real one; `make icons` makes every size from it. Tried in a
scratch prefix: installed in 3.5 s, the installed copy opened a window on
a private X server with class `guiltty` and a 128x128 icon, and
uninstalling left no files.

Later: your logo arrived as four SVGs (the mark, a favicon, the lockup,
the lockup on a card). The app icon is made from your pieces: the card's
dark rounded square with the mark in its lavender (`logo.svg`). At 16
pixels the cursor bar and the chevron merged into something like "D_", so
16 and 24 come from `logo-small.svg`, just `>_`, a bit bolder. ImageMagick
here refuses SVG (security policy) and rsvg-convert isn't installed, so
`make icons` renders with headless Chromium unless rsvg-convert is there.

## 2026-10-30 — Closing the window quits, unless you ask it not to

_Draft: agent, awaiting user_

You noticed guiltty "started where you left it". It wasn't starting at
all: closing the window had left the shells running (detach, since MVP 4),
and the next window showed the same shells. That's now opt-in:
`on_close: :quit` (default) closes every tab when you close the window,
so the last tab ending stops guiltty, as after the last `exit`;
`on_close: :detach` keeps the old behavior. A renderer crash still just
reopens the window. Checked with an installed copy on a private X server:
asked its window to close the way a window manager does, and the whole
node was gone a moment later.

Later: `on_close` didn't last an hour. Your better idea: quit by default,
and lock just the tabs you want to keep (Ctrl+Shift+L, a 🔒 in the tab
bar). Closing the window closes the unlocked ones; the locked ones keep
guiltty running for the next window. Tried live with an installed copy:
two tabs, one locked, window closed, guiltty still running with just the
locked tab, and the reopened window showed it. The new unknown-name check
caught the example config still saying `on_close`. And the 🔒 came out as
a plain white lock: Source Code Pro has its own, and guiltty used any open
font that covered a character before asking for an emoji font. Now emoji
look for an emoji font first.

## 2026-10-30 — MVP 9: Broadcast

_Draft: agent, awaiting user_

**Tried.** Your idea, typing once into many SSH tabs, with the risk you
spotted: a dropped connection quietly turns a tab into your local shell.
The answer was already in the kernel: every terminal has a foreground
process group (`tcgetpgrp`), and when ssh exits the shell takes it back.
A tab joins the group (Ctrl+Shift+B) only while ssh or mosh-client is in
its foreground, and that process is remembered. Before every keystroke,
and once a second, every tab is checked; if one changed, nothing is sent
anywhere and the bar says `⚠ broadcast paused: tab 2 disconnected`. Host
names come from ssh's command line in /proc. Tabs owns the group, next to
the tab list and the locks.

**Broke.** No sshd here, so the live test used a copy of `cat` named
`ssh` (the kernel names a process after its file), which "drops" on
Ctrl+D. My first live run looked like a failure: a keystroke meant for
nowhere went through. My own script had pressed Ctrl+Shift+B once too
often and taken the tab out of the group. The test for the race between
the check and the write isn't possible: the gap is real but microseconds,
and it's written down in chapter 18 instead.

**Clicked.** Two tabs broadcasting, a third left alone; one tab's "ssh"
ends; the next keystroke goes to nobody; the bar turns red with ⚠ on the
lost tab.

### Later

- A tiled view of the group, to watch every server's output at once.
- Flag tabs whose output differs from the others (a failed command on one
  server).

Later: you had to `ssh localhost` to put your own machine in the group.
Now a local tab can join on purpose: the first Ctrl+Shift+B says it's
local, a second within three seconds adds it, marked 🏠. It isn't
checked, because there's no connection to lose and every local command
takes the foreground. The second press is what keeps a tab whose ssh just
died from slipping in as "local".

## 2026-10-30 — MVP 10: Vulkan

_Draft: agent, awaiting user_

**Tried.** A second backend behind the seam that's been waiting since
MVP 1: same cells, same two instanced draws, same shaders (ported to
Vulkan's GLSL, compiled to SPIR-V by glslc, baked in with `#embed`). What
GL's driver does quietly is code now: picking a GPU that can present to
this window, a swapchain rebuilt when the window resizes, two frames in
flight with fences and semaphores, the atlas uploaded through a staging
buffer with layout barriers around the copy. Vulkan is the default; if it
can't start, the Window starts the OpenGL renderer in its place and says
so in the bar. To test it without a screen, the renderer learned to
replay recorded port messages and save a screenshot.

**Broke.** The first run under the validation layers found one error:
`discard` compiles to "demote to helper invocation" for Vulkan 1.3, which
must be switched on even though every 1.3 GPU has it. The fallback first
watched for "died before its hello", which never happens: the renderer
says hello before it makes its window. The real sign is "died before
drawing a frame". RADV can't present on Xvfb (no DRI3), so live tests
there run on lavapipe, and RADV was tested on an offscreen surface.

**Clicked.** OpenGL and Vulkan, from the same recording: 0 of 359,476
pixels differ, on the RX 6600 and on lavapipe. Four live resizes under the
validation layers: not one message.

### Later

- Only redraw dirty rows into each frame's cell buffer (today every frame
  copies all cells: a few hundred KB, not worth the bookkeeping yet).
- MAILBOX present mode for lower latency where the driver has it.
- A Wayland run (only X11 has been tried).

## 2026-10-30 — A changelog, and install instructions for someone else

_Draft: agent, awaiting user_

You asked for a changelog and an install guide for people who don't have
Elixir yet. `CHANGELOG.md` covers every tag from v0.1.0 to v0.10.0, put
together from the tags, the commits and this devlog. Two entries I had
filed by memory were wrong, and git corrected them (`working_directory`
came in 0.6.0, not 0.7.0). The README now goes from nothing to an
installed guiltty: a table of what to install and why, one command each
for openSUSE, Fedora, Ubuntu and Arch, then `./install.sh`. The package
names for the three I can't try were checked against their package
sites. Two traps found that way: Ubuntu 26.04's Elixir is 1.18 (too old),
and the NIF needs `erl_nif.h`, which Ubuntu ships separately in
`erlang-dev`.

Writing it for a stranger found a real bug: on a fresh Elixir, `mix
deps.get` stops to ask about installing Hex, and telemetry needs rebar3.
install.sh hides that output, so the install would have hung silently.
It now installs both itself (`mix local.hex --force --if-missing`).
Also fixed: four chapters and the overview still named `guiltty_gl` as
the renderer.

Not tried: a full install on a clean machine, or Elixir 1.20 on an
older Erlang/OTP than 29.

## 2026-10-30 — Tabs like the website mockup

_Draft: agent, awaiting user_

A mockup for the website drew guiltty's tabs nicer than guiltty draws
them: just the title, lots of air, no numbers, no `│` between tabs. You
asked for that look as pure style, without touching sizes. So
`build_tab_bar` now pads each title with two cells on each side and
drops the number, the separator and the bold on the active tab. The bar
is still one cell row, so the grid math and mouse clicks are untouched.

What we gave up: the numbers were the only hint for Ctrl+Shift+1..9 (I
first told you no such keys existed; they do). The mockup's other trick,
a taller bar with the text centered and a gap under it, needs the bar to
stop being a grid row, and stays for later.

### Later
- A taller tab bar with centered text and a gap under it, like the
  mockup (its own pixel height instead of cells row 0).

## 2026-10-30 — Ligatures

_Draft: agent, awaiting user_

You asked whether guiltty does ligatures (it didn't), and then for them
in 0.11.0. The reason it didn't: every cell is shaped alone, so HarfBuzz
never sees `-` and `>` side by side, and the font's rules never fire.

The fix is a second pass over each row. Runs of ASCII punctuation in one
style are shaped together with the primary font, and every glyph is
compared with the character's plain one. JetBrains Mono turned out to
keep one glyph per character: `->` becomes an empty spacer and a
`hyphen_greater.liga` that draws the whole arrow back over the first
cell. "Different from the plain glyph" catches that and the classic
one-glyph ligature alike. Each span then goes into the atlas the way a
wide character does, N slots side by side, so the backends, the shaders
and Elixir didn't change. The only protocol change is a flag bit in
OPTIONS (version 9).

You picked: on by default, the cursor doesn't break a ligature, and only
punctuation is checked (letters would mean shaping every word on every
update). What clicked: `fonts_render` already drew multi-character text
across several cells, so drawing a ligature needed no new code.

Not tried: Fira Code (not installed), and how it feels while typing.
Tests use JetBrains Mono and skip themselves without it.

## 2026-10-30 — Security, step 1: hardened builds and two analyzers

_Draft: agent, awaiting user_

v0.12.4 is the security MVP: guiltty won't be as fast as Ghostty, but its
C should be very hard to break. Step one was the cheap layers.

Every C file is now built with the hardening flags from the OpenSSF
guide (FORTIFY_SOURCE=3, the stack protector, stack-clash protection,
CET, zeroed locals, PIE, full RELRO, no executable stack). `readelf`
shows them in the binaries. The new warnings found one thing: an
ignored `chdir` in the forked child, which GCC doesn't let a `(void)`
cast hide.

`make analyze` runs GCC's `-fanalyzer` and Clang's analyzer. Between
them they found four things. GCC: `block()` indexed its quadrant table
with only a lower bound on the character (safe only because its one
caller checked), and a false fd leak in `--replay`. Clang:
`shape_run` trusted `fonts_ligatures`, in another file, to stay inside
the run, and `decode_cell` left colors unset if a read could fail.
Nothing crashed, but each was safe only because of code somewhere else.
All fixed, and each analyzer found what the other missed.

Also decided: distribution stays on for the launcher, but locked down
(a later step), and the performance ideas wait.

### Later
- Speed: a launcher that doesn't boot two VMs (pidfile + FIFO, or a
  small C client on a Unix socket): about 4 s to open today, about
  0.7 s cold and near-instant warm after.
- Throughput benchmarks and profiling; upload only the rows that
  changed.

## 2026-10-30 — Security, step 2: fuzzing, Valgrind, and a launcher race

_Draft: agent, awaiting user_

Two fuzz targets now hammer the renderer's input. `fuzz_framing` is the
`{:packet, 4}` reader; `fuzz_messages` is the whole message path,
`read_setup` then `apply_message` and `draw`, the real code included
whole, with the GPU swapped for a backend that checks what it's asked
to draw. A fuzz input is a replay file, so any crash replays in the real
renderer. Ten minutes each: 248 thousand message inputs and 8.5 million
framing inputs, no crash. Writing the harness found a real bug first:
the renderer used `SDL_GetWindowSizeInPixels`'s results without checking
it had succeeded, in five places.

The first run "found" a leak that wasn't one: fontconfig keeps some
pointers as encoded offsets, so LeakSanitizer can't follow them. The fix
excuses exactly that path, which needs full stack traces, at about half
the speed. Valgrind was expected to drown in Mesa noise; it reported
nothing at all, on both renderers.

Then you benchmarked against alacritty and ghostty and `hyperfine
guiltty` failed with status 1. Two things were going on. Alacritty's
times are how long each window stayed open; guiltty's launcher hands the
window to a background node and returns, so the numbers don't compare.
And the launcher had a race: if the window closed while it was talking
to the node, it reached a node that was shutting down, and failed. A
test that closes the window at different moments during a launch caught
it (2 failures in 8 with the old launcher, 0 in 16 with the new one).
The new launcher returns as soon as it has started a node (that node
opens its own window), and if a running node can't open a window, it
waits for it to finish and starts a new one.

### Later
- Several windows, each with its own tabs (today `guiltty` raises the
  one window).

## 2026-10-30 — Security, step 3: the PTY NIF audit

_Draft: agent, awaiting user_

The NIF read well: sizes checked, everything copied before `fork`, only
async-signal-safe calls in the child. The audit still found five things,
none of them ever seen to happen, which is the point.

The worst was signals by pid. The BEAM ignores SIGCHLD, so the kernel
reaps a shell the moment it exits, and its pid is free. The reaper task
did `wait` (running), then `kill(pid, SIGKILL)`: if the shell exited
between the two and its pid went to another tab's shell, that one died.
It needs a pid to come round in milliseconds, out of 4 million, so it's
rare, but it's the kind of thing that happens once and can't be
explained. The child is now held as a pidfd, which means that one
process forever; once it's gone, signals fail with ESRCH.

The rest: a lock per pty (the Pty process and the reaper task can call
into the same resource from two threads), `close` marking the pty closed
before the BEAM gets round to closing the fd, a `read` that could have
handed out a stale buffer tail if shrinking it ever failed, `kill`
accepting any number as a signal, and an instant where the PTY fds
weren't close-on-exec (now `posix_openpt(O_CLOEXEC)` and `TIOCGPTPEER`).

I first described the close race as wider than it was: the old
`pty_stop` did mark the fd closed, just a few instructions after closing
it, on another thread. Checking that against the old code before
handing over is what caught it.

New tests throw junk at every argument (StreamData's `term()`), call a
closed pty and a dead one, hammer one pty from sixteen processes while
one closes it, and count the BEAM's open files after fifty open/close
cycles. Against the old NIF, only the signal-range test fails: the races
can't be provoked on demand.

## 2026-10-30 — Security, step 4: what programs can make guiltty do

_Draft: agent, awaiting user_

The good news first: guiltty answers only four queries, all with text it
makes itself. No title reports, no clipboard for programs, no window
operations. A property test now feeds thousands of random escape
sequences and checks every answer is one of those four shapes.

Two real findings. The first: answers nobody reads. I expected the
kernel to hold them, and in line mode it does (it discards what doesn't
fit). In raw mode it refuses them instead, so they waited in the Pty: a
program sending 300,000 queries left 2.7 MB behind, three times what it
sent, with no limit. A server over ssh could run guiltty out of memory
that way. Answers now go through `Pty.answer/2`, which keeps whole
answers while the backlog is under 64 KB. The first version of the cap
let one batch through on top (73 KB), because a single read of queries
makes about 190 KB of answers at once; the test caught it.

The second: tab titles could wear guiltty's own markers. A server
calling itself "📡 prod" would look like a tab in the broadcast group.
Titles now lose the markers, bidi controls (Elixir itself refuses those
in source code, I found out trying to test it) and control characters,
and are made valid UTF-8.

Also: `RESIZE` from the renderer is capped at 4096 x 4096, its own limit.

## 2026-10-30 — Security, step 5: closing the network door

_Draft: agent, awaiting user_

The launcher reaches the running guiltty over Erlang distribution, and
distribution's only lock is the cookie: whoever has it and can reach the
port can run anything as you. Three things were wrong. The node listened
on every interface. The cookie was on the VM's command line, `-setcookie
47UYX...`, which `ps` shows to every user (it was even in the log). And
the COOKIE file was 0644, saved only by a 0700 home folder.

Now the node is `guiltty@127.0.0.1` and listens only there
(`inet_dist_use_interface` in vm.args, for the launcher's nodes too).
The cookie comes from `~/.erlang.cookie`: Mix's start script passes
`--cookie` in four places, so a release step in mix.exs removes them, and
fails the build if Mix ever writes the script differently. Checked on a
test release: no cookie in /proc/PID/cmdline, the port on 127.0.0.1
only, a wrong cookie gets `pang`.

The surprise was speed. The race test from step 2 suddenly "failed":
closes at 0.9 s and later found no window. They were landing after the
launcher had finished: a warm `guiltty` now takes 0.8 s instead of 2.5 s,
because the short name made Erlang look up a hostname that doesn't
resolve, on every call. The test now tells closes during a launch (21 of
them, all fine) from closes after.

That's all five steps. MVP 12 is ready for its loot and the tag.

## 2026-10-30 — Multi window, step 1: desks

_Draft: agent, awaiting user_

You asked for windows that are 100% independent. The one window was
built in deep: a global `Tabs` with the tab list, the active tab, the
locked set and the broadcast group, a Window registered under one name,
and `open_window` that raised it. Tabs could already attach several
windows, but they'd all have shown the same tabs.

So each window is now a *desk*: a little supervisor with its own Tabs
and its own Window, rest_for_one, ending when its Tabs ends. Sessions
stay where they were, under one global supervisor, but with ids unique
across desks (`System.unique_integer`) and their desk's id stored as the
Registry value, so a Tabs that crashes takes back its own sessions and
nobody else's. "guiltty stops when the last tab closes" used to be Tabs
being significant; with many Tabs that can't work, so a small
`Lifeline` watches the desks and is the significant one.

The Window barely changed: it's told which Tabs is its own and passes
it along. Most of the diff is that, and the tests following suit.

Not done yet: a closed window's locked tabs keep running in their desk,
but nothing opens it again. That and Ctrl+Shift+N are step 2.

## 2026-10-30 — Multi window, steps 2 and 3: windows that come back

_Draft: agent, awaiting user_

With desks in place, the rest was mostly deciding what "a window comes
back" means. A window closed with locked tabs leaves its desk running
with no Window: its Window child is still in the supervisor, just not
running, which `Supervisor.which_children` reports as `:undefined`. The
next `guiltty` finds the oldest such desk and gives it a new window.
Replacing the child, not restarting it: the new launch may come from
another display, and the old child spec remembers the old one.
Ctrl+Shift+N skips all that and asks for a fresh desk.

One test turned flaky along the way: the PTY fd-leak test counted the
BEAM's open files before and after and wanted them equal. The new desk
tests leave reaper tasks behind that close their pidfds a moment later,
so the count sometimes *dropped* during the test. A leak can only make
it grow, so the test now waits for the count to settle and checks it
didn't go up.

v0.13.0 is ready: book chapter 21 has the story, with the real Registry
of two windows (desk 1 owning sessions 2 and 5, desk 3 owning 4).

## 2026-10-31 — v0.14.0: Performance

_Draft: agent, awaiting user_

The rule for this one was: measure, then fix what the numbers say,
without changing what guiltty is. So first `make bench`: the parser and
grid alone, and a real shell `cat`-ing into a real window. Scrolling text
went through the grid at 0.8 MB/s.

The profile pointed at small things. A fifth of the time was building a
set of all forty row numbers on every line feed, to say "every row
changed"; now that's `:all`. Then batching: `seq` reaches the grid as
thousands of print, CR, LF, and each one shifted the whole screen and
saved one row; now plain lines are laid down together and the screen
scrolls once. The first try barely helped, and counting calls showed
why: a read that ended mid-line left the cursor mid-row, and the whole
next read gave up on the fast path. Then trimming scrollback rows: a
binary search instead of `longest_common_suffix`, and rows that scroll
straight off are made short from the start. 0.8 became 4.4 MB/s.

An equivalence test (fast path vs one command at a time, on random
lines) caught a difference no one would have seen: the newest scrollback
rows were trimmed one way and full width the other. Fixed anyway; the
test is what makes the fast path safe to keep.

The Vulkan renderer now uploads only changed rows, per frame in flight,
like OpenGL. To test it, replays now draw a frame per update, the way a
live window does, and thirty small updates must end on the picture of
one whole update; a planted bug (only the current slot marked stale)
fails it. Honest number: at 120x40 this saves microseconds.

Boot: almost all of a cold start is the VM itself (~0.35 s bare, the JIT
compiling every module it loads). Interactive mode loads modules as
they're used: ~100 ms sooner to the first frame.

You kept the launcher out of scope, so it's still ~0.7 s of a cold start.

### Later
- A launcher that doesn't boot a VM (pidfile + FIFO).
- Colored lines in the batch path (following SGR inside a batch).
- A faster parser scanner.

## 2026-10-31 — v0.15.0: Client and server

_Draft: agent, awaiting user_

You didn't want a pidfile and FIFO in shell ("a workaround"), and the
honest answer was that the launcher was already shell, booting a second
VM to ask "are you running?". So it's now the Emacs way: a C client of
about 200 lines that decides nothing, and an Elixir process,
`Guiltty.Launcher`, on a Unix socket in a folder only you can open.

The interesting part was the race that had broken twice. While the last
window closes, the old node still holds the name `guiltty@127.0.0.1`,
and a node started with `-name` then can't start. The fix moved the name
out of the boot: the release starts without distribution, and
`Guiltty.Distribution` takes the name once it's free. That needed epmd,
which a node only starts by itself when named at boot; tried on a
private epmd port first (`econnrefused`), so guiltty starts it. The
Launcher is the last child, so it closes first when guiltty stops, and
until then answers "shutting down" so the client asks again.

On a release, through a link like the installed one: cold launch 0.71 s
to the window (was 1.33), warm 85 ms (was ~0.9 s). 24 launches right
after closing the window: 24 windows. The command itself returns in
4 ms when guiltty runs.

A small surprise in the tests: a line over the socket's 4 KB limit gets
the connection closed before the error can be sent. Fine for a hostile
client; but the C client would then have read it as "shutting down" and
retried for 5 s, so it now leaves out any display value over 1 KB.

### Later
- A systemd user service, server mode (no window at boot, stay running).
- Turning distribution off entirely (only `stop` and `remote` use it).

## 2026-10-31 — v0.15.0, continued: server mode and the service

_Draft: agent, awaiting user_

You asked for the rest of the Emacs model: start guiltty first, then
use the client. Server mode is small: `GUILTTY_SERVER=1` leaves out the
boot window, and Lifeline doesn't stop when the last desk ends.
`./install.sh --service` writes a systemd user unit for it (checked with
`systemd-analyze verify`), stops and restarts it around updates, and
removes it on uninstall.

Tested on a release run the way systemd runs it (foreground, no
DISPLAY): no window at boot, a window from the client in 15 ms, still
running after the last window closed, warm again after, and SIGTERM
gives a clean exit 0, so systemd won't restart it.

Testing it found a real gap: windows get their display from the
request, but the shells in their tabs only had the node's environment,
and a service started before the desktop has no DISPLAY. `xdg-open` from
a tab would have failed. A desk now passes its window's display
variables to its tabs' shells.

Two more for the service, after asking what wouldn't work with it. Tab
shells inherited systemd's environment, whose PATH is the system's only:
on openSUSE `~/.local/bin` comes from `/etc/profile`, read by login
shells only, so `guiltty` itself wasn't found in a tab. Server mode now
starts shells as login shells, the `login(1)` way, with a dash in front
of the name (`-zsh`); checked that openSUSE's `/etc/zprofile` sources
`/etc/profile`, so zsh gets it too. And the client now sends its folder
(`getcwd`, not `$PWD`), so a new window's first tab starts where you ran
`guiltty`, in both modes.

Then taken back out: server mode, `install.sh --service` and the login
shells. Weighing it plainly, the service saves about 0.6 s on the first
window after login, and costs a different environment in every tab:
systemd's, not your session's. Each gap could be patched (the display,
login files), but every patch is something a user would have to debug
when a tab behaves unlike any other terminal's. You'd rather pay 0.7 s
once and have shells that behave like everyone else's. Chapter 23 keeps
the reasoning under "Why there's no service". Kept from that work: the
first tab starts in the folder you ran `guiltty` in, and a window's
display reaches its tabs' shells.

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

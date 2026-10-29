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

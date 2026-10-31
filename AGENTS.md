# AGENTS.md

Instructions for coding agents working on **guiltty**, a GPU terminal emulator
written in Elixir and C. The C is a PTY NIF, a renderer that runs as a separate
OS process, and the `guiltty` client, plus fuzz targets and tools for
development. By lines, C is a bit under half the code: don't describe it as "a
little C".

The build plan (`guiltty — build plan`, Oct 27 2026) is the source of truth for
scope. This file covers how to carry it out.

## Working agreement

The plan was written for building guiltty by hand. That changed: **the agent
writes the code and the user reviews and approves it.** The user has very little
free time, so every change has to be cheap to review and has to teach
something.

- **You are the hands, the user is the gate.** Nothing is merged, tagged or pushed
  without their explicit approval. Don't move on to the next step of the plan
  until the current one is approved.
- **Small slices.** Hand over one step from an MVP's "Suggested order" at a
  time, small enough to review in a few minutes. If a step gets past a few
  hundred lines, hand it over in parts.
- **Review notes with every change.** When you hand a change over, include:
  1. what changed and why, in two or three sentences;
  2. where to look first, with file and line links, and which parts are
     boilerplate that can be skimmed;
  3. the **loot**: the Linux, BEAM or GPU concepts the change relies on, each
     with the man page or doc section to read (for example `openpty(3)`,
     `ioctl_tty(2)` TIOCSCTTY, `erl_nif` enif_select);
  4. how the user can check it themselves in under five minutes (a command to run
     and what they should see).
- **Loot over speed still applies.** "If the feature works but you can't
  explain the loot, the MVP isn't done" now means: an MVP isn't done until
  the user has read the loot notes and can answer the MVP's questions.
- **Ask, don't guess, on design decisions** that the plan doesn't settle
  (protocol layouts, process ownership, anything hard to change later).
  Present a recommendation with the tradeoff in a few lines. Pick the obvious
  option for small details and mention it in the review notes.
- **Stay in scope.** Each MVP lists what's in and out of scope. Don't build
  ahead. Note out-of-scope ideas in `DEVLOG.md` under "Later".

## Git: the user commits

- **Never commit, and never create or switch branches.** Work directly on
  `master` and leave every change uncommitted in the working tree. The user
  reviews the diff and commits it themselves.
- Don't stage, stash, reset, tag, push or open PRs either. Read-only commands
  (`git status`, `git diff`, `git log`) are fine.
- **Bonfire:** before every boss attempt (risky changes such as the first
  fork/exec, the first OpenGL frame or a protocol change), stop and tell the
  user it's a good moment to commit, so there is a known-good point to return
  to. Wait for them before starting the risky part.
- **Tags** (`v0.1.0`, `v0.2.0`, `v0.3.43`, `v0.4.0`, `v0.5.0`) are created by
  the user once every "Done when" item for that MVP is approved. Remind them
  when an MVP is ready.
- When handing over, you can suggest a commit message in the review notes.

## Devlog

After each working session, append a dated entry to `DEVLOG.md`: what was
tried, what broke and what clicked. Write it in plain language, because it's
the first draft of a book. Mark it as an agent draft
(`_Draft: agent, awaiting user_`) so the user can rewrite it in their own voice.

## Changelog

`CHANGELOG.md` lists what each version changed for someone using guiltty:
features, settings, fixes, new build requirements. Add every user-visible
change to "Unreleased" in the same change, in plain words. When the user
tags a version, rename "Unreleased" to that version and date. Anything
that breaks an existing config goes under "Changed" or "Removed".

## The book

`book/` holds Org-mode files (`.org`) that explain how guiltty works, so
the user can understand the whole program without reading every line of code.
The devlog records what happened in each session. The book describes how the
program works now.

- **One file per topic**, numbered in reading order, for example
  `00-overview.org`, `01-pseudoterminals.org`, `02-pty-nif.org`,
  `03-parser.org`, `04-screen-and-grid.org`, `05-port-protocol.org`,
  `06-renderer.org`, `07-input.org`, `08-supervision.org`. Add files as new
  topics appear. `book/index.org` links them all in order.
- **Keep it current.** Any change to how something works updates the matching
  chapter in the same change. Reviewing that chapter is part of reviewing the
  change.
- **Explain from the bottom up:** the concept first (what a PTY is, what the
  line discipline does), then how guiltty uses it, then where it lives in the
  code, linking to files with `[[file:../c_src/pty_nif.c::openpty][...]]`
  style links.
- **Diagrams in every chapter where they help:** data flow, process trees,
  supervision trees, state machines, wire formats and sequence diagrams for
  things like startup and shutdown. Draw them as ASCII art in
  `#+begin_example` blocks so they read correctly in any editor, on GitHub and
  in plain text. For complex graphs, you can add a Graphviz `dot` source
  block (`#+begin_src dot :file images/<name>.svg`) next to the ASCII version
  so the user can render it with org-babel.
- **Show real data:** actual bytes from the fixtures, real port messages and
  grid dumps from iex, rather than made-up examples.
- **End each chapter with "Loot"** (the concepts and the man pages to read)
  and **"Questions"**: a few questions the user should be able to answer after
  reading it, with the answers in a folded `:answers:` drawer or a collapsed
  subtree.
- Plain, friendly prose. Short sections and headings that work well with
  Org folding.

## Architecture

```
guiltty/
├── lib/guiltty/
│   ├── application.ex
│   ├── lifeline.ex          # watches the desks; guiltty stops after the last
│   ├── launcher.ex          # the socket the `guiltty` command asks for windows
│   ├── distribution.ex      # takes the node's name once it's free (releases)
│   ├── desk.ex              # one per window: its Tabs and its Window
│   ├── tabs.ex              # one window's tabs, locks, broadcast group
│   ├── window.ex            # owns the renderer port, input events, keymap
│   ├── keymap.ex
│   └── session/
│       ├── supervisor.ex    # rest_for_one: pty, screen, parser
│       ├── pty.ex           # owns the PTY NIF resource
│       ├── screen.ex        # authoritative grid, sends row updates
│       └── parser.ex
├── c_src/
│   ├── pty_nif.c            # openpty, spawn, enif_select
│   ├── client/guiltty.c     # the `guiltty` command: asks the running guiltty
│   │                        # for a window over a Unix socket, or starts it
│   └── renderer/
│       ├── core/            # port protocol, SDL3 window and input, glyph atlas,
│       │                    # fonts (fontconfig fallback, HarfBuzz, FreeType),
│       │                    # sprites (box drawing and blocks drawn by guiltty)
│       ├── gl/              # OpenGL 3.3 core backend (MVP 1)
│       └── vk/              # Vulkan 1.3 backend (MVP 10, the default)
├── priv/                    # built binaries: guiltty_vk, guiltty_gl (+ -dbg builds)
├── Makefile                 # built through elixir_make
├── test/fixtures/           # recorded byte streams
├── book/                    # Org-mode guide to how guiltty works (see "The book")
└── DEVLOG.md
```

Rules that keep the architecture intact:

- **Elixir owns behavior and the authoritative screen; C owns syscalls and
  pixels.** The grid lives in the `Screen` process as plain terms.
- **The only C inside the BEAM is the PTY NIF.** The renderer is always a
  separate process behind an Erlang port, so a renderer crash takes down a
  window and never a session.
- **The client has no logic.** `c_src/client/guiltty.c` connects, sends
  one versioned request, prints the answer and exits, or execs the
  release. Every decision about windows is made in Elixir
  (`Guiltty.Launcher`, `Guiltty.Lifeline`).
- **The backend seam exists from day one.** The renderer core never includes
  GL or Vulkan headers. Backends implement a struct of function pointers
  (init, upload atlas, draw frame, resize, shutdown) and declare the SDL
  window flags they need. Each backend builds into its own binary, and
  `config.exs` picks which one `Window` launches.
- **The port protocol** uses `{:packet, 4}` framing and a small binary
  protocol. The renderer's first message is a hello carrying the protocol
  version and backend name, and `Window` refuses a version mismatch. Any
  protocol change bumps the version.

## PTY NIF rules

- Between `fork()` and `exec` the child may only make async-signal-safe calls
  (`setsid`, `ioctl`, `dup2`, `close`, `execvp`, `_exit`), because the BEAM is
  multithreaded. No `malloc`, no `printf`, no `enif_*` calls in the child.
  Prepare argv and envp before forking.
- `setsid()` comes before `ioctl(TIOCSCTTY)`.
- The parent closes its copy of the slave fd after fork.
- The master fd lives in a NIF resource. Its destructor closes the fd and
  makes sure the child is reaped (no zombie bash processes).
- No reader thread: use `enif_select` for readability, then read in a NIF
  call. Reads are non-blocking (`O_NONBLOCK`) and never block a scheduler.
  From MVP 4, re-arm `enif_select` only when the parser has caught up
  (kernel backpressure).
- `TERM=dumb` in MVP 1 and `TERM=xterm-256color` from MVP 2.

## C conventions

- C23, compiled with `-std=c23 -Wall -Wextra -Wpedantic -Wformat=2
  -Wshadow -Wvla -Wnull-dereference`, warning-free, with the hardening
  flags in the Makefile (`HARDEN`, `HARDEN_LD`). Debug builds add
  `-fsanitize=address,undefined`. `make analyze` stays clean: fix
  findings; silence one only for a proven false positive, scoped to that
  function, with a comment saying why.
- Use `<stdckdint.h>` (`ckd_add`, `ckd_mul`) for every size calculation:
  atlas dimensions, buffer lengths and message sizes read from the port.
  Treat sizes from the port as untrusted input.
- Use `#embed` to bake GLSL shaders (later SPIR-V) into the binary.
- Protocol message tags are typed enums (`enum msg_tag : uint8_t`), and
  `static_assert` pins wire-struct sizes.
- Use `nullptr`, `constexpr`, `typeof` and `bool`.
- Put `[[nodiscard]]` on every function that returns an error,
  `[[fallthrough]]` in protocol `switch` statements and `unreachable()` for
  impossible states.
- Comment the *why*, especially for syscalls: the reviewer is learning from
  the code, so a one-line note naming the man page next to a non-obvious call
  is welcome. Don't narrate what the code obviously does.

## Elixir conventions

- `mix format` clean and `mix compile --warnings-as-errors` clean.
- Session processes run under a `rest_for_one` supervisor in the order `Pty`,
  `Screen`, `Parser`.
- Parser and grid are pure functions where possible, so they can be tested
  without processes.

## Config options

Every new setting in `config.exs` needs all of these, in the same change:

- a default in `Guiltty.Config.defaults/0` (its name is then a known name;
  anything else is reported as a typo);
- a check in `Guiltty.Config.build_checked/1` that turns a bad value into
  `{:error, "name: what was expected"}`, never a crash. The test "every
  setting rejects a value of the wrong shape" fails until it exists;
- a commented line in `priv/config.example.exs`;
- a row in the table in `book/16-config.org`.

## Testing

- **Byte fixtures:** record real sessions with `script` (util-linux) into
  `test/fixtures/`. Don't hand-type escape sequences when a recording is
  possible.
- **Golden tests:** fixture bytes in, a text dump of the grid out, compared to
  a snapshot.
- **Property tests** (StreamData, from MVP 2): random bytes never crash the
  parser, and any chunking of the same bytes gives the same grid.
- **Renderer replay:** save port messages to a file and replay them into the
  renderer on its own, under ASan, UBSan and Valgrind.
- **Fuzzing** (from MVP 12): `c_src/fuzz/` targets take replay files.
  A crash the fuzzer finds is fixed, then copied (minus any OPEN_URL
  message) into `test/fixtures/fuzz/messages/`, where `mix test` replays
  it. After a protocol change, regenerate the seeds.
- **Oldest supported versions:** Elixir 1.18 on Erlang/OTP 26
  (`mix.exs`, README, book chapter 10). Don't use an API newer than
  those without asking. Before a version tag that touched Elixir code,
  run the suite on Elixir 1.18.4 / OTP 26 too (book chapter 10, "Running
  the suite on another version"), in a copy of the project.
- Run the relevant tests before handing over a change, and report failures
  as they are. Don't hide them.

## Commands

```sh
mix deps.get
mix compile                 # also builds c_src/ into priv/ via elixir_make
mix test
mix format --check-formatted
mix guiltty                 # dev: open a window; closing it ends everything
_build/prod/rel/guiltty/lib/guiltty-*/priv/guiltty   # the release's `guiltty` command (C client)
iex -S mix                  # same, with an iex shell alongside
make debug                  # renderer with ASan + UBSan (also built by `make`)
make analyze                # GCC and Clang static analyzers over all C; any finding fails
make fuzz-run               # libFuzzer on the renderer's input (FUZZ_TIME=600 s per target)
make valgrind               # both release renderers replay the recordings under Valgrind
make bench                  # throughput: parser + grid alone, then a real window (book chapter 22)
mix run --no-start test/fixtures/fuzz/make_seeds.exs   # regenerate fuzz seeds (protocol change)
make width-table            # regenerate the Unicode width table from glibc's wcwidth
make icons                  # regenerate the icons from priv/icons/logo.svg (+ logo-small.svg)
./install.sh                # install for the user into ~/.local (--uninstall to remove)
./priv/guiltty_gl-dbg --demo   # the renderer alone, no Elixir
./priv/guiltty_vk-dbg --replay test/fixtures/replay/session.msgs --screenshot x.ppm
                               # replay recorded port messages, save the last frame
```

Tests run the `-debug` renderer headless (`SDL_VIDEO_DRIVER=offscreen`).
Set `config :guiltty, renderer: "guiltty_vk-dbg"` (or `"guiltty_gl-dbg"`)
to run the app under the sanitizers; the Vulkan one also turns on the
validation layers. With no Vulkan GPU, `VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json`
picks lavapipe (Mesa's software Vulkan).

## Environment

The user's machine is openSUSE (packages via `zypper`), with:

- GCC 16, Elixir 1.20 on OTP 29 (via asdf)
- FreeType, fontconfig, HarfBuzz, OpenGL and EGL development files present
- Fonts: Source Code Pro (monospace), JetBrainsMono Nerd Font, Noto Color
  Emoji. No CJK font yet (`noto-sans-cjk-fonts`), so kanji draw as tofu.
- Keyboard: US-International (dead keys), X11 input method `@im=local`
- Xvfb and Xephyr are installed: use a private display (`Xvfb :77`) for
  tests that need real X key or mouse events, never the user's display
- SDL3 3.4, an X11 session (`DISPLAY=:0`)
- AMD RX 6600 (RADV), Vulkan loader 1.4, glslc (shaderc), the Khronos
  validation layers, vulkan-tools. RADV can't present on Xvfb (no DRI3):
  Vulkan tests on Xvfb or offscreen run on lavapipe or a headless surface
- Clang 23 (with LLVM, for libFuzzer and `make analyze`) and Valgrind
- Ask before installing system packages and give the exact `zypper`
  command.

## References

`pty(7)`, `termios(3)`, `console_codes(4)`, XTerm control sequences
(ctlseqs), the DEC ANSI parser by Paul Williams (vt100.net), ECMA-48,
vttest, `erl_nif`, Elixir `Port`, the SDL3 wiki, LearnOpenGL, vkguide.dev,
vulkan-tutorial.com, FreeType docs, `st` (suckless), Ghostty and Alacritty.

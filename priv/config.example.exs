# guiltty's config: copy to ~/.config/guiltty/config.exs.
#
# It's plain Elixir: the last expression is the config, a keyword list.
# guiltty reloads it within a second of every save, and applies it to the
# open window. If it doesn't evaluate, the error is logged and the
# previous config stays.

[
  font: [family: "monospace", size: 18],

  # A built-in theme by name: "guiltty" (the icon's lavender on
  # near-black, what guiltty uses without a config), "tomorrow-night",
  # "catppuccin-mocha", "dracula", "gruvbox-dark", "solarized-dark",
  # "nord", "tokyo-night", "one-dark" or "catppuccin-latte" (light).
  theme: "guiltty",

  # Or your own colors. Any you leave out come from `name:` (or from
  # guiltty without one):
  #
  # theme: [
  #   name: "catppuccin-mocha",
  #   fg: "#c5c8c6",
  #   bg: "#1d1f21",
  #   cursor: "#c5c8c6",
  #   # black, red, green, yellow, blue, magenta, cyan, white, then bright
  #   ansi: ~w(#1d1f21 #cc6666 #b5bd68 #f0c674 #81a2be #b294bb #8abeb7 #c5c8c6
  #            #969896 #d54e53 #b9ca4a #e7c547 #7aa6da #c397d8 #70c0b1 #eaeaea),
  #   # The tab bar's colors. Any you leave out are worked out from the
  #   # theme, to suit the tab_style.
  #   tab_bar: "#282a36",          # the bar behind the tabs
  #   tab_text: "#6272a4",         # the other tabs' titles
  #   tab_active: "#ff79c6",       # the active tab's background
  #   tab_active_text: "#282a36",  # the active tab's title
  #   tab_accent: "#ff79c6",       # the line along the active tab (flat,
  #                                # minimal), the filled tab's color (others)
  #   # The border between split panes, and along the focused one. Left
  #   # out: the palette's bright black and blue.
  #   pane_border: "#44475a",
  #   pane_border_active: "#bd93f9"
  # ],

  # :block, :bar or :underline. Programs can change it while they run (vim
  # shows a bar in insert mode); it comes back when they're done.
  # password_lock: a lock in place of the cursor while a program (sudo,
  # ssh) reads a password with echo off.
  cursor: [style: :block, blink: false, password_lock: true],

  window: [
    # Pixels around the text (more on a HiDPI screen).
    padding: 6,
    # The size of a new window, in cells.
    columns: 80,
    rows: 24,
    # The background's opacity, 0.1 to 1.0. Needs a compositor; applies to
    # windows opened after a change.
    opacity: 1.0
  ],

  # The program each new tab runs. Without a command: your login shell.
  # shell: [command: "/usr/bin/zsh", args: ["-l"]],

  # Where a new tab starts: :inherit (where the current tab's shell is),
  # :home, or a path.
  working_directory: :inherit,

  # Selecting text copies it to the primary selection (middle click pastes
  # it); :clipboard copies it to the clipboard too; false copies nothing
  # until Ctrl+Shift+C.
  copy_on_select: true,

  # Rows the mouse wheel scrolls per step.
  wheel_lines: 3,

  # Bold text in the 8 basic colors uses their bright versions, as xterm
  # does.
  bold_is_bright: true,

  # Broadcast (Ctrl+Shift+B): a tab may join only while it runs one of
  # these. If one of them stops (a dropped connection), typing goes nowhere
  # until that tab leaves the group. A local tab (your own shell) joins on
  # a second Ctrl+Shift+B, and isn't checked.
  broadcast_programs: ["ssh", "mosh-client"],

  # Where the tabs go: :bottom (the default) or :top.
  tab_bar: :bottom,

  # How the tabs look:
  #   :flat        (the default) side by side, the active one lighter, with
  #                a line along its edge
  #   :powerline   colored blocks joined by arrows
  #   :rounded     pills with round ends, the active one filled
  #   :minimal     no bar: titles on the terminal's background, the line
  #                under the active one
  #   :separators  titles between thin bars, the active one filled
  # Their colors are in theme: (tab_bar, tab_active, ... above).
  tab_style: :flat,

  # The border between split panes (Ctrl+Shift+O / E): one cell wide, a
  # line of style :solid, :dashed, :double or :none (blank), :thin or
  # :thick. Its colors are in theme: (pane_border, pane_border_active).
  pane_border: [style: :solid, thickness: :thin],

  # Join ->, !=, |>, => and the like into one symbol, when the font has
  # ligatures (JetBrains Mono and Fira Code do; Source Code Pro doesn't).
  ligatures: true,

  # How guiltty draws: :vulkan, or :gl (OpenGL). If Vulkan can't start
  # (no driver, no GPU that can show the window), guiltty says so and
  # draws with OpenGL. Applies to windows opened after a change.
  # GUILTTY_RENDERER=gl (or vulkan) in guiltty's environment wins over
  # this, to try the other one for a run: `guiltty stop`, then
  # `GUILTTY_RENDERER=gl guiltty`.
  renderer: :vulkan,

  # Rows of output each tab keeps for scrolling back (new tabs only).
  scrollback: 10_000,

  # Each action takes a list of keys. Names: letters, digits, f1-f12,
  # tab, enter, page_up, page_down, home, end, insert, delete, up, down,
  # left, right, plus (the + key), or a punctuation character like = or -,
  # with any of the ctrl+, shift+ and alt+ modifiers.
  #
  # A punctuation key is named by what it types *without* Shift on your
  # layout. "ctrl+shift+/" is the / ? key on a US keyboard; on a Latin
  # American one / is Shift+7, so no key matches it there, and the ' ?
  # key is "ctrl+shift+'". Letters are the same on every layout.
  keys: [
    # A new window, with its own tabs (closing it never touches the others).
    new_window: ["ctrl+shift+n"],
    new_tab: ["ctrl+shift+t"],
    # Closes the focused pane (the tab, when it's the last one). Asks first
    # when it's running a program (vim, ssh, a build).
    close_tab: ["ctrl+shift+w"],
    next_tab: ["ctrl+page_down", "ctrl+tab"],
    prev_tab: ["ctrl+page_up", "ctrl+shift+tab"],
    move_tab_left: ["ctrl+shift+page_up"],
    move_tab_right: ["ctrl+shift+page_down"],
    # Type a name for the tab, Enter (empty: the program's title again).
    rename_tab: ["ctrl+shift+r"],
    scroll_page_up: ["shift+page_up"],
    scroll_page_down: ["shift+page_down"],
    scroll_top: ["shift+home"],
    scroll_bottom: ["shift+end"],
    # Drops the tab's scrollback; what's on the screen stays.
    clear_scrollback: ["ctrl+shift+k"],
    search: ["ctrl+shift+f"],
    copy: ["ctrl+shift+c"],
    # Selects everything: the scrollback and the screen, as in an editor.
    select_all: ["ctrl+shift+a"],
    # Ctrl and the + key: "plus" names the key that types + without Shift
    # (Latin American, Spanish, German layouts).
    zoom_in: ["ctrl+=", "ctrl+shift+=", "ctrl+plus"],
    zoom_out: ["ctrl+-"],
    zoom_reset: ["ctrl+0"],
    # Opens this file in your editor (creating it from the example first).
    open_config: ["ctrl+,"],
    # Shows every key (this list, as you bound it).
    cheatsheet: ["ctrl+shift+h", "ctrl+shift+/"],
    # Locks the tab: closing the window ends every tab but the locked ones,
    # which keep running; the next `guiltty` brings that window back with
    # them, where you left them.
    lock_tab: ["ctrl+shift+l"],
    # Puts the tab in the broadcast group, or takes it out: all its panes.
    broadcast: ["ctrl+shift+b"],
    # Opens the AI tool set below, and goes back. Many newer laptops have
    # an AI key, usually right of the space bar: it sends Super+Shift+F23, so it
    # works here too.
    ai: ["ctrl+shift+space", "super+shift+f23"],
    # Split panes: a new pane right of the focused one, or below it, with
    # half its room.
    split_right: ["ctrl+shift+o"],
    split_down: ["ctrl+shift+e"],
    # The focus to the pane in that direction (a click works too).
    focus_left: ["ctrl+shift+left"],
    focus_right: ["ctrl+shift+right"],
    focus_up: ["ctrl+shift+up"],
    focus_down: ["ctrl+shift+down"],
    # Jumps to the prompt before or after the view (a shell must mark them:
    # OSC 133).
    prev_prompt: ["ctrl+shift+z"],
    next_prompt: ["ctrl+shift+x"],
    # Moves the separator nearest the focused pane, that way.
    resize_left: ["alt+shift+left"],
    resize_right: ["alt+shift+right"],
    resize_up: ["alt+shift+up"],
    resize_down: ["alt+shift+down"]
  ],

  # The AI tool the `ai` key opens, beside you (:right, :down) or in a tab of its
  # own (:tab). It's a program in a pane: what's selected goes to its prompt, and
  # nothing else on your screen does. Without a command, the key only says so.
  # ai: [command: "", position: :right],

  # Programs can put text on the clipboard (OSC 52), from the focused pane.
  # They can never read it.
  # clipboard_write: true,

  # Ctrl+click opens URLs in plain text (http, https, mailto, file), like the
  # one a server prints when it starts. Hold Ctrl to see them underlined.
  # Links a program marks (OSC 8) open either way.
  # link_url: true,

  # Answer DECRQCRA and the title reports, for terminal test suites. Leave it
  # off: these let a program read your screen, even from the far end of ssh.
  # screen_reports: false
]

# guiltty's config: copy to ~/.config/guiltty/config.exs.
#
# It's plain Elixir: the last expression is the config, a keyword list.
# guiltty reloads it within a second of every save, and applies it to the
# open window. If it doesn't evaluate, the error is logged and the
# previous config stays.

[
  font: [family: "monospace", size: 18],

  # A built-in theme by name: "catppuccin-mocha", "tomorrow-night" (what
  # guiltty uses without a config), "dracula", "gruvbox-dark" or
  # "solarized-dark".
  theme: "catppuccin-mocha",

  # Or your own colors. Any you leave out come from `name:` (or from
  # tomorrow-night without one):
  #
  # theme: [
  #   name: "catppuccin-mocha",
  #   fg: "#c5c8c6",
  #   bg: "#1d1f21",
  #   cursor: "#c5c8c6",
  #   # black, red, green, yellow, blue, magenta, cyan, white, then bright
  #   ansi: ~w(#1d1f21 #cc6666 #b5bd68 #f0c674 #81a2be #b294bb #8abeb7 #c5c8c6
  #            #969896 #d54e53 #b9ca4a #e7c547 #7aa6da #c397d8 #70c0b1 #eaeaea)
  # ],

  # :block, :bar or :underline. Programs can change it while they run (vim
  # shows a bar in insert mode); it comes back when they're done.
  cursor: [style: :block, blink: false],

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

  # Closing the window :quit's guiltty (its tabs end). With :detach the tabs
  # keep running, and the next guiltty opens them where you left them.
  on_close: :quit,

  # Where the tabs go: :top or :bottom.
  tab_bar: :top,

  # Rows of output each tab keeps for scrolling back (new tabs only).
  scrollback: 10_000,

  # Each action takes a list of keys. Names: letters, digits, f1-f12,
  # tab, enter, page_up, page_down, home, end, insert, delete, or a
  # punctuation character like = or -, with any of the ctrl+, shift+ and
  # alt+ modifiers.
  keys: [
    new_tab: ["ctrl+shift+t"],
    close_tab: ["ctrl+shift+w"],
    next_tab: ["ctrl+page_down", "ctrl+tab"],
    prev_tab: ["ctrl+page_up", "ctrl+shift+tab"],
    scroll_page_up: ["shift+page_up"],
    scroll_page_down: ["shift+page_down"],
    scroll_top: ["shift+home"],
    scroll_bottom: ["shift+end"],
    search: ["ctrl+shift+f"],
    copy: ["ctrl+shift+c"],
    zoom_in: ["ctrl+=", "ctrl+shift+="],
    zoom_out: ["ctrl+-"],
    zoom_reset: ["ctrl+0"],
    # Opens this file in your editor (creating it from the example first).
    open_config: ["ctrl+,"],
    # Shows every key (this list, as you bound it).
    cheatsheet: ["ctrl+shift+/"]
  ]
]

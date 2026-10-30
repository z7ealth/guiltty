# guiltty's config: copy to ~/.config/guiltty/config.exs.
#
# It's plain Elixir: the last expression is the config, a keyword list.
# guiltty reloads it within a second of every save, and applies it to the
# open window. If it doesn't evaluate, the error is logged and the
# previous config stays.

[
  font: [family: "monospace", size: 18],
  theme: [
    fg: "#c5c8c6",
    bg: "#1d1f21",
    cursor: "#c5c8c6",
    # black, red, green, yellow, blue, magenta, cyan, white, then bright
    ansi: ~w(#1d1f21 #cc6666 #b5bd68 #f0c674 #81a2be #b294bb #8abeb7 #c5c8c6
             #969896 #d54e53 #b9ca4a #e7c547 #7aa6da #c397d8 #70c0b1 #eaeaea)
  ],
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
    zoom_reset: ["ctrl+0"]
  ]
]

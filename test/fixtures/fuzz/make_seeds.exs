# Seeds for the fuzz targets (c_src/fuzz/): one valid example of every
# message Elixir sends the renderer, made with the real encoders, so the
# fuzzer starts from inputs that get past the first checks. Regenerate
# after a protocol change:
#
#   mix run --no-start test/fixtures/fuzz/make_seeds.exs
#
# (--no-start: without it, guiltty itself starts and opens a window.)
alias Guiltty.{Grid, Parser, Terminal, Theme}
alias Guiltty.Window.Protocol

dir = Path.dirname(__ENV__.file)

frame = fn messages ->
  Enum.map(messages, fn m ->
    bin = IO.iodata_to_binary(m)
    [<<byte_size(bin)::32>>, bin]
  end)
end

screen = fn text, cols, rows ->
  {_parser, commands} = Parser.feed(Parser.new(), text)
  grid = Terminal.apply(Grid.new(cols, rows), commands)

  %{
    size: {cols, rows},
    rows: Grid.snapshot(grid),
    cursor: Grid.cursor(grid),
    cursor_visible: true,
    cursor_style: {:bar, true},
    clusters: Map.to_list(grid.clusters)
  }
end

options = %{padding: 6, opacity: 1.0, bold_is_bright: true, ligatures: true}
font = %{family: "monospace", size: 16}

# Text that reaches every path of the row code: colors and attributes,
# wide characters, clusters, emoji, a Nerd Font icon, box drawing,
# blocks, ligature runs.
text =
  "\e[1;31mred\e[0m \e[4;7mu\e[0m 日本 é 👍🏽 🇯🇵  ok\r\n" <>
    "┌─┐ ▀▄█░▒▓ ▖▗▘▙ -> != |> === <!-- -->\r\n\e[38;2;1;2;3mrgb\e[0m"

seeds = %{
  "all" => [
    Protocol.setup(30, 4, Theme.default(), font, options),
    Protocol.tabs(["🔒 one -> two", "日本語", "three"], 1),
    # Every tab style, so each way of drawing the bar is reached; one with
    # its own colors.
    Protocol.tab_style(:powerline, %{Theme.default() | tab_accent: {255, 121, 198}}),
    Protocol.tab_style(:rounded, Theme.default()),
    Protocol.tab_style(:minimal, %{Theme.default() | tab_bar: {0, 0, 0}}),
    Protocol.tab_style(:separators, Theme.default()),
    Protocol.tab_style(:flat, Theme.default()),
    Protocol.rows(screen.(text, 30, 4)),
    Protocol.title("a title"),
    Protocol.status("search: 3 of 7"),
    Protocol.status(:warning, "config.exs:3: bad value"),
    Protocol.theme(Theme.default()),
    Protocol.options(%{options | padding: 8}),
    Protocol.options(Map.put(options, :tab_bar, :bottom)),
    Protocol.halo({255, 0, 0}, 300),
    Protocol.clipboard(:clipboard, "copied"),
    Protocol.raise_window(),
    Protocol.font(%{font | size: 20}),
    # A password being read: the lock in place of the cursor.
    Protocol.rows(Map.put(screen.("[sudo] password: ", 30, 4), :cursor_secret, true)),
    Protocol.rows(screen.("after", 30, 4))
  ],
  # Images (Kitty graphics): each format, placements of every shape (own
  # size, cells, one of the two, cut by the grid's edge, under and over
  # the text), then one dropped while a placement still names it.
  "images" => [
    Protocol.setup(20, 6, Theme.default(), font, options),
    Protocol.image(1, %{format: :rgb, width: 3, height: 2, data: :binary.copy(<<255, 0, 0>>, 6)}),
    Protocol.image(2, %{
      format: :rgba,
      width: 2,
      height: 2,
      data: :binary.copy(<<0, 255, 0, 128>>, 4)
    }),
    Protocol.image(3, %{
      format: :png,
      width: 30,
      height: 40,
      data: File.read!(Path.join(dir, "../images/red.png"))
    }),
    Protocol.placements({20, 6}, [
      %{uid: 1, row: 0, col: 0, offset: {0, 0}, source: {0, 0, 3, 2}, cells: {0, 0}, z: -1},
      %{uid: 2, row: -1, col: 18, offset: {3, 4}, source: {1, 0, 1, 2}, cells: {4, 0}, z: 0},
      %{uid: 3, row: 4, col: 2, offset: {0, 0}, source: {0, 0, 30, 40}, cells: {0, 3}, z: 5},
      %{uid: 3, row: 1, col: 5, offset: {0, 0}, source: {0, 0, 0, 0}, cells: {2, 2}, z: -9}
    ]),
    Protocol.rows(screen.("over the images", 20, 6)),
    Protocol.image_drop(1),
    Protocol.rows(screen.("dropped", 20, 6))
  ],
  "resize" => [
    Protocol.setup(10, 2, Theme.default(), font, options),
    # An update for a size the renderer doesn't have: dropped.
    Protocol.rows(screen.("old size", 20, 3)),
    Protocol.rows(screen.("fits", 10, 2))
  ]
}

for {name, messages} <- seeds, target <- ["messages", "framing"] do
  File.write!(Path.join([dir, target, "#{name}.msgs"]), frame.(messages))
end

for target <- ["messages", "framing"] do
  File.cp!(Path.join(dir, "../replay/session.msgs"), Path.join([dir, target, "session.msgs"]))
end

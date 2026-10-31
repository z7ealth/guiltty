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
    Protocol.rows(screen.("after", 30, 4))
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

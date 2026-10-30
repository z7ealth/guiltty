defmodule Guiltty.Cheatsheet do
  @moduledoc """
  Every key guiltty has, on one page, like NvChad's cheatsheet: cards in
  columns, one per group, each line an action and its keys.

  The keys come from the config, so rebinding a key changes the sheet.

  It's drawn the way a program would draw it: escape sequences (cursor
  moves, colors, box-drawing characters) fed through `Guiltty.Parser` and
  `Guiltty.Terminal` into a grid as tall as the sheet. The Window then
  shows a screenful of its rows instead of the tab's screen. Colors are
  palette indices, so the sheet follows the theme.
  """

  alias Guiltty.{Grid, Parser, Terminal}

  @card_width 42
  @min_card_width 36
  @gap 2

  # Title colors for the cards, as palette indices: blue, green, magenta,
  # yellow, cyan, red, round and round.
  @accents [4, 2, 5, 3, 6, 1]

  @doc "The groups, as `[{title, [{action label, keys}]}]`."
  def groups(config) do
    k = &keys(config.keys, &1)

    [
      {"Tabs",
       [
         {"New tab", k.(:new_tab)},
         {"Close tab", k.(:close_tab)},
         {"Next tab", k.(:next_tab)},
         {"Previous tab", k.(:prev_tab)},
         {"Go to tab 1-9", "Ctrl+Shift+1..9"},
         {"Switch tab", "click it"},
         {"Keep after closing", k.(:lock_tab)}
       ]},
      {"Scrollback",
       [
         {"Page up", k.(:scroll_page_up)},
         {"Page down", k.(:scroll_page_down)},
         {"To the top", k.(:scroll_top)},
         {"Back to the bottom", k.(:scroll_bottom)},
         {"Scroll", "mouse wheel"}
       ]},
      {"Search",
       [
         {"Search", k.(:search)},
         {"Older match", "Enter"},
         {"Newer match", "Shift+Enter"},
         {"End search", "Esc"}
       ]},
      {"Copy & paste",
       [
         {"Copy", k.(:copy)},
         {"Paste", "Ctrl+Shift+V / Shift+Ins"},
         {"Select", "drag"},
         {"Select word / line", "double / triple click"},
         {"Paste the selection", "middle click"},
         {"Select in vim, htop...", "hold Shift"}
       ]},
      {"Zoom",
       [
         {"Zoom in", k.(:zoom_in)},
         {"Zoom out", k.(:zoom_out)},
         {"Normal size", k.(:zoom_reset)}
       ]},
      {"guiltty",
       [
         {"Open the config", k.(:open_config)},
         {"This cheatsheet", k.(:cheatsheet)}
       ]}
    ]
  end

  @doc """
  The whole sheet for a screen `cols` wide, as a list of grid rows (each
  `cols` cells). It can be taller than the screen; the Window scrolls it.
  """
  def render(config, cols) do
    groups = groups(config)
    # As many full-width cards as fit; but rather two narrower ones than
    # one column on a standard 80-column window.
    room = cols - 2 + @gap
    fit = max(max(div(room, @card_width + @gap), min(div(room, @min_card_width + @gap), 2)), 1)
    width = min(@card_width, div(cols - 2 + @gap, fit) - @gap) |> max(12)

    # A grid, balanced: 6 cards with room for 5 per row are 3 + 3, not 5 + 1.
    rows_needed = ceil(length(groups) / fit)
    per_row = ceil(length(groups) / rows_needed)

    cards =
      groups
      |> Enum.with_index()
      |> Enum.map(fn {{title, entries}, i} ->
        {title, Enum.flat_map(entries, &fit_entry(&1, width - 4)),
         Enum.at(@accents, rem(i, length(@accents)))}
      end)

    # The block is centered; the title and the help line up with its edges.
    block = per_row * width + (per_row - 1) * @gap
    left = max(div(cols - block, 2), 0)

    # Row by row; every card in a row as tall as the tallest, so their tops
    # and bottoms line up.
    {placed, bottom} =
      cards
      |> Enum.chunk_every(per_row)
      |> Enum.map_reduce(2, fn row, y ->
        lines = row |> Enum.map(fn {_t, lines, _a} -> length(lines) end) |> Enum.max()

        placed =
          row
          |> Enum.with_index()
          |> Enum.map(fn {card, i} -> {card, left + i * (width + @gap), y, lines} end)

        {placed, y + lines + 3}
      end)

    help = "Esc closes, arrows scroll"

    sheet =
      [
        "\e[?7l",
        at(0, left, "\e[1mguiltty keys\e[0m"),
        # On the right edge of the block, if there's room after the title.
        if(block - String.length(help) >= 16,
          do: at(0, left + block - String.length(help), "\e[38;5;8m#{help}\e[0m"),
          else: []
        )
        | Enum.map(List.flatten(placed), fn {card, x, y, lines} ->
            card(card, x, y, width, lines)
          end)
      ]

    {_parser, commands} = Parser.feed(Parser.new(), IO.iodata_to_binary(sheet))
    grid = Terminal.apply(Grid.new(cols, bottom - 1), commands)
    Tuple.to_list(grid.lines)
  end

  # An action and its keys on one line, or, when they don't fit, the keys
  # on a second line of their own, on the right.
  defp fit_entry({label, keys}, inner) do
    if String.length(label) + String.length(keys) + 1 <= inner,
      do: [{label, keys}],
      else: [{label, ""}, {"", cut(keys, inner)}]
  end

  # A card: a rounded box with the title on its top edge, then one line per
  # action, its keys on the right, and blank lines up to `height` lines.
  defp card({title, entries, accent}, x, y, width, height) do
    entries = entries ++ List.duplicate({"", ""}, height - length(entries))
    inner = width - 4
    border = "\e[38;5;8m"
    reset = "\e[0m"
    rule = String.duplicate("─", max(width - String.length(title) - 5, 0))

    top =
      at(
        y,
        x,
        "#{border}╭─#{reset}\e[1;38;5;#{accent}m #{title} #{reset}#{border}#{rule}╮#{reset}"
      )

    lines =
      entries
      |> Enum.with_index(1)
      |> Enum.map(fn {{label, keys}, i} ->
        dots = max(inner - String.length(label) - String.length(keys), 0)

        at(
          y + i,
          x,
          "#{border}│#{reset} #{label}#{String.duplicate(" ", dots)}\e[38;5;#{accent}m#{keys}#{reset} #{border}│#{reset}"
        )
      end)

    bottom =
      at(y + length(entries) + 1, x, "#{border}╰#{String.duplicate("─", width - 2)}╯#{reset}")

    [top, lines, bottom]
  end

  # CUP: rows and columns count from 1 in escape sequences.
  defp at(row, col, text), do: ["\e[#{row + 1};#{col + 1}H", text]

  defp cut(text, room) do
    if String.length(text) <= room, do: text, else: String.slice(text, 0, room - 1) <> "…"
  end

  ## Key names, as people write them

  defp keys(bindings, action) do
    case Map.get(bindings, action, []) do
      [] -> "(none)"
      names -> Enum.map_join(names, " / ", &pretty/1)
    end
  end

  @names %{
    "ctrl" => "Ctrl",
    "shift" => "Shift",
    "alt" => "Alt",
    "page_up" => "PgUp",
    "page_down" => "PgDn",
    "escape" => "Esc",
    "enter" => "Enter",
    "tab" => "Tab",
    "home" => "Home",
    "end" => "End",
    "insert" => "Ins",
    "delete" => "Del",
    "backspace" => "Backspace",
    "up" => "Up",
    "down" => "Down",
    "left" => "Left",
    "right" => "Right"
  }

  @doc false
  def pretty(name) do
    name
    |> String.split("+")
    |> Enum.map_join("+", fn part -> Map.get_lazy(@names, part, fn -> String.upcase(part) end) end)
  end
end

defmodule Guiltty.View do
  @moduledoc """
  What the window shows of a grid: the live screen, or `scroll` rows back
  into the scrollback, with the selection and the search matches marked.

  Marks are attribute bits on the copies of the rows sent to the renderer,
  never on the grid itself: the selection flips `inverse`, a search match
  gets `match`, and the match you're on gets `current_match` too. The link
  under the pointer while Ctrl is held gets `underline`, as in Ghostty, so
  you can see what a click would open. Reverse video (DECSCNM) flips
  `inverse` on every cell.

  Colors a program changed (OSC 4, 10, 11) are swapped in here too, in
  `recolor/2`. The renderer has one palette for the whole window, and these
  belong to one pane.

      scroll = 0                    scroll = 2
      +----------------+            +----------------+
      | screen row 0   |            | scrollback -2  |
      | screen row 1   |            | scrollback -1  |
      | screen row 2   |            | screen row 0   |
      +----------------+            +----------------+
  """

  import Bitwise

  alias Guiltty.{Grid, Search, Selection}

  @doc "The row number (see `Guiltty.Grid`) of the top row shown."
  def top(grid, scroll), do: grid.history - scroll

  @doc "How far back the view can go."
  def clamp_scroll(grid, scroll), do: scroll |> max(0) |> min(Grid.scrollback_size(grid))

  @doc "Whether the view differs from the grid's own rows."
  def decorated?(scroll, selection, search), do: scroll > 0 or selection != nil or search != nil

  @doc """
  Every visible row, as `[{index, row}]`. `underline` is a list of
  `{row number, first col, last col}` to underline (the hovered link).
  """
  def rows(grid, scroll, selection, search, underline \\ []) do
    top = top(grid, scroll)

    for i <- 0..(grid.rows - 1) do
      n = top + i

      line =
        (Grid.line(grid, n) || blank(grid.cols))
        |> mark_matches(grid, n, search)
        |> mark_underline(n, underline)
        |> mark_selection(grid, n, selection)
        |> mark_reverse(grid)

      {i, line}
    end
  end

  @doc "Whether the program changed any color, so rows need `recolor/2`."
  def recolored?(grid),
    do: map_size(grid.palette) > 0 or grid.fg_color != nil or grid.bg_color != nil

  @doc "A row with the program's colors in place of the palette's and the default ones."
  def recolor(line, grid) do
    fg = rgb(grid.fg_color)
    bg = rgb(grid.bg_color)

    for <<head::binary-size(6), cell_fg::32, cell_bg::32 <- line>>, into: <<>> do
      <<head::binary, swap_color(cell_fg, fg, grid.palette)::32,
        swap_color(cell_bg, bg, grid.palette)::32>>
    end
  end

  # 0 is the default color; 0x01_0000NN is palette entry NN (see Guiltty.Grid).
  defp swap_color(0, default, _palette), do: default

  defp swap_color(color, _default, palette) when map_size(palette) > 0 and color >>> 24 == 1 do
    case palette do
      %{^color => _} -> color
      _ -> palette |> Map.get(color &&& 0xFF) |> palette_rgb(color)
    end
  end

  defp swap_color(color, _default, _palette), do: color

  defp palette_rgb(nil, color), do: color
  defp palette_rgb(rgb, _color), do: rgb(rgb)

  defp rgb(nil), do: 0
  defp rgb({r, g, b}), do: Grid.rgb(r, g, b)

  @doc "Where the cursor shows, or nil when it's scrolled out of view."
  def cursor(grid, scroll) do
    {row, col} = Grid.cursor(grid)
    if row + scroll < grid.rows, do: {row + scroll, col}
  end

  @doc """
  The keyboard hints over `rows` (from `rows/5`, whose first row is row
  number `top`): each `{label, spans}` underlines its link and writes its
  label over the link's first cells, in reverse video so it stands out
  from any text.
  """
  def hints(rows, _top, []), do: rows

  def hints(rows, top, hints) do
    marks = Grid.attr(:inverse) ||| Grid.attr(:bold)

    Enum.reduce(hints, Map.new(rows), fn {label, spans}, rows ->
      in_view = Enum.filter(spans, fn {n, _, _} -> Map.has_key?(rows, n - top) end)

      rows =
        Enum.reduce(in_view, rows, fn {n, c1, c2}, rows ->
          Map.update!(
            rows,
            n - top,
            &update_attrs(&1, c1..c2, fn a -> a ||| Grid.attr(:underline) end)
          )
        end)

      case in_view do
        [{n, c1, _} | _] -> Map.update!(rows, n - top, &put_label(&1, c1, label, marks))
        [] -> rows
      end
    end)
    |> Enum.sort()
  end

  # The label's letters over the cells from col on, as far as the row goes.
  defp put_label(line, col, label, marks) do
    size = Grid.cell_size()
    cols = div(byte_size(line), size)

    label
    |> String.to_charlist()
    |> Enum.with_index(col)
    |> Enum.filter(fn {_char, c} -> c < cols end)
    |> Enum.reduce(line, fn {char, c}, line ->
      offset = c * size

      <<before::binary-size(^offset), _glyph::32, attrs::16, colors::binary-size(8),
        after_::binary>> = line

      # The label replaces the whole cell, so a wide character under it
      # loses its wide and spacer marks.
      attrs = (attrs &&& bnot(Grid.attr(:wide) ||| Grid.attr(:spacer))) ||| marks
      <<before::binary, char::32, attrs::16, colors::binary, after_::binary>>
    end)
  end

  defp mark_matches(line, _grid, _n, nil), do: line

  defp mark_matches(line, grid, n, %{query: query, match: current}) do
    grid
    |> Search.matches_in_row(n, query)
    |> Enum.reduce(line, fn {c1, c2}, line ->
      bits =
        if current == {n, c1, c2},
          do: Grid.attr(:match) ||| Grid.attr(:current_match),
          else: Grid.attr(:match)

      update_attrs(line, c1..c2, &(&1 ||| bits))
    end)
  end

  defp mark_underline(line, _n, []), do: line

  defp mark_underline(line, n, spans) do
    Enum.reduce(spans, line, fn
      {^n, c1, c2}, line -> update_attrs(line, c1..c2, &(&1 ||| Grid.attr(:underline)))
      _span, line -> line
    end)
  end

  defp mark_selection(line, _grid, _n, nil), do: line

  defp mark_selection(line, grid, n, selection) do
    case Selection.cols_in_row(grid, selection, n) do
      nil -> line
      cols -> update_attrs(line, cols, &bxor(&1, Grid.attr(:inverse)))
    end
  end

  defp mark_reverse(line, %{reverse_video: false}), do: line

  defp mark_reverse(line, _grid) do
    for <<glyph::32, attrs::16, colors::binary-size(8) <- line>>, into: <<>> do
      <<glyph::32, bxor(attrs, Grid.attr(:inverse))::16, colors::binary>>
    end
  end

  defp update_attrs(line, cols, fun) do
    size = Grid.cell_size()

    for {<<glyph::32, attrs::16, colors::binary-size(8)>>, col} <-
          Enum.with_index(for <<cell::binary-size(^size) <- line>>, do: cell),
        into: <<>> do
      attrs = if col in cols, do: fun.(attrs), else: attrs
      <<glyph::32, attrs::16, colors::binary>>
    end
  end

  defp blank(cols), do: :binary.copy(<<?\s::32, 0::16, 0::32, 0::32>>, cols)
end

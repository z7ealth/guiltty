defmodule Guiltty.View do
  @moduledoc """
  What the window shows of a grid: the live screen, or `scroll` rows back
  into the scrollback, with the selection and the search matches marked.

  Marks are attribute bits on the copies of the rows sent to the renderer,
  never on the grid itself: the selection flips `inverse`, a search match
  gets `match`, and the match you're on gets `current_match` too.

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

  @doc "Every visible row, as `[{index, row}]`."
  def rows(grid, scroll, selection, search) do
    top = top(grid, scroll)

    for i <- 0..(grid.rows - 1) do
      n = top + i

      line =
        (Grid.line(grid, n) || blank(grid.cols))
        |> mark_matches(grid, n, search)
        |> mark_selection(grid, n, selection)

      {i, line}
    end
  end

  @doc "Where the cursor shows, or nil when it's scrolled out of view."
  def cursor(grid, scroll) do
    {row, col} = Grid.cursor(grid)
    if row + scroll < grid.rows, do: {row + scroll, col}
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

  defp mark_selection(line, _grid, _n, nil), do: line

  defp mark_selection(line, grid, n, selection) do
    case Selection.cols_in_row(grid, selection, n) do
      nil -> line
      cols -> update_attrs(line, cols, &bxor(&1, Grid.attr(:inverse)))
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

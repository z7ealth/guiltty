defmodule Guiltty.Search do
  @moduledoc """
  Finding text in the scrollback and on the screen.

  Matches are found within a row (a match can't span two rows). The search
  ignores case unless the query has an uppercase letter ("smart case", as
  in vim and less). A match is `{row_number, first_col, last_col}`, with
  row numbers as `Guiltty.Grid` counts them.
  """

  alias Guiltty.Grid

  @type match :: {integer(), non_neg_integer(), non_neg_integer()}

  @doc """
  The next match before (`:older`) or after (`:newer`) position
  `{row_number, col}`, searching row by row. `nil` starts from the bottom
  (`:older`) or the top (`:newer`) of everything.
  """
  @spec find(Grid.t(), binary(), {integer(), integer()} | nil, :older | :newer) :: match() | nil
  def find(_grid, "", _from, _direction), do: nil

  def find(grid, query, nil, :older), do: find(grid, query, {grid.history + grid.rows, 0}, :older)

  def find(grid, query, nil, :newer),
    do: find(grid, query, {grid.scrollback_first - 1, 0}, :newer)

  def find(grid, query, {n, col}, direction) do
    query = fold(query, query)
    first = grid.scrollback_first
    last = grid.history + grid.rows - 1

    # The starting row first (only the matches past `col`), then row by row.
    candidates =
      case direction do
        :older -> Stream.iterate(min(n, last), &(&1 - 1)) |> Stream.take_while(&(&1 >= first))
        :newer -> Stream.iterate(max(n, first), &(&1 + 1)) |> Stream.take_while(&(&1 <= last))
      end

    Enum.find_value(candidates, fn row ->
      matches = matches(grid, row, query)

      case direction do
        :older -> matches |> Enum.filter(&(row < n or elem(&1, 0) < col)) |> List.last()
        :newer -> Enum.find(matches, &(row > n or elem(&1, 0) > col))
      end
      |> then(fn
        nil -> nil
        {c1, c2} -> {row, c1, c2}
      end)
    end)
  end

  @doc "Every match in row `n`, as `[{first_col, last_col}]`."
  def matches_in_row(_grid, _n, ""), do: []
  def matches_in_row(grid, n, query), do: matches(grid, n, fold(query, query))

  defp matches(grid, n, {query, fold?}) do
    with line when line != nil <- Grid.line(grid, n),
         text = grid |> Grid.line_text(line) |> maybe_downcase(fold?),
         true <- String.contains?(text, query) do
      cells = cells(grid, line, fold?)
      find_all(cells, String.graphemes(query), [])
    else
      _ -> []
    end
  end

  # [{col, text}] for every cell that shows something (spacers skipped).
  defp cells(grid, line, fold?) do
    for {<<glyph::32, _::binary-size(10)>>, col} <- chunks(line),
        glyph != 0,
        do: {col, grid |> Grid.glyph_text(glyph) |> maybe_downcase(fold?)}
  end

  defp chunks(line) do
    size = Grid.cell_size()
    for(<<cell::binary-size(^size) <- line>>, do: cell) |> Enum.with_index()
  end

  # Compare cell by cell: each cell holds one grapheme of the query.
  defp find_all([], _query, acc), do: Enum.reverse(acc)

  defp find_all([{col, _} | rest] = cells, query, acc) do
    if starts_with?(cells, query) do
      {last_col, _} = Enum.at(cells, length(query) - 1)
      find_all(Enum.drop(cells, length(query)), query, [{col, last_col} | acc])
    else
      find_all(rest, query, acc)
    end
  end

  defp starts_with?(_cells, []), do: true
  defp starts_with?([{_col, text} | cells], [text | query]), do: starts_with?(cells, query)
  defp starts_with?(_cells, _query), do: false

  defp fold(query, original) do
    fold? = String.downcase(original) == original
    {maybe_downcase(query, fold?), fold?}
  end

  defp maybe_downcase(text, true), do: String.downcase(text)
  defp maybe_downcase(text, false), do: text
end

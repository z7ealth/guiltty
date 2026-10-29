defmodule Guiltty.Grid do
  @moduledoc """
  Grid v0: a fixed-size screen of ASCII cells and a cursor.

  Each row is a binary of `cols` bytes, so a row is also exactly what gets
  drawn. Rows that change are remembered as dirty until `take_dirty/1`.

  The cursor column may equal `cols`: the last cell was just written and the
  wrap is pending. The next printable character wraps to a new line; a CR
  doesn't, so a line of exactly `cols` characters plus CR LF doesn't leave an
  empty line behind. xterm behaves the same way.
  """

  alias Guiltty.Parser

  defstruct [:cols, :rows, :lines, row: 0, col: 0, dirty: MapSet.new()]

  @type t :: %__MODULE__{}

  @tab_width 8

  @spec new(pos_integer(), pos_integer()) :: t()
  def new(cols \\ 80, rows \\ 24) do
    blank = blank_line(cols)
    lines = Tuple.duplicate(blank, rows)
    %__MODULE__{cols: cols, rows: rows, lines: lines, dirty: MapSet.new(0..(rows - 1))}
  end

  @spec apply(t(), [Parser.command()]) :: t()
  def apply(grid, commands), do: Enum.reduce(commands, grid, &command/2)

  @doc "The cursor as `{row, col}`, clamped to a visible cell."
  @spec cursor(t()) :: {non_neg_integer(), non_neg_integer()}
  def cursor(grid), do: {grid.row, min(grid.col, grid.cols - 1)}

  @doc "Returns `[{row_index, row}]` for changed rows and clears the dirty set."
  @spec take_dirty(t()) :: {[{non_neg_integer(), binary()}], t()}
  def take_dirty(grid) do
    rows = grid.dirty |> Enum.sort() |> Enum.map(&{&1, elem(grid.lines, &1)})
    {rows, %{grid | dirty: MapSet.new()}}
  end

  @doc "All rows as `[{row_index, row}]`, for a full redraw."
  @spec snapshot(t()) :: [{non_neg_integer(), binary()}]
  def snapshot(grid), do: grid.lines |> Tuple.to_list() |> Enum.with_index(fn l, i -> {i, l} end)

  @doc "The screen as text, trailing spaces trimmed. For iex and tests."
  @spec dump(t()) :: String.t()
  def dump(grid) do
    grid.lines
    |> Tuple.to_list()
    |> Enum.map_join("\n", &String.trim_trailing/1)
  end

  defp command({:print, text}, grid), do: print(grid, text)
  defp command(:cr, grid), do: %{grid | col: 0}
  defp command(:lf, grid), do: line_feed(grid)
  defp command(:bs, grid), do: %{grid | col: max(min(grid.col, grid.cols - 1) - 1, 0)}

  defp command(:ht, grid) do
    next = (div(grid.col, @tab_width) + 1) * @tab_width
    %{grid | col: min(next, grid.cols - 1)}
  end

  defp print(grid, <<>>), do: grid

  defp print(%{col: col, cols: cols} = grid, text) when col >= cols do
    grid |> Map.put(:col, 0) |> line_feed() |> print(text)
  end

  # Write as much of the text as fits on this row in one go.
  defp print(grid, text) do
    n = min(grid.cols - grid.col, byte_size(text))
    <<chunk::binary-size(^n), rest::binary>> = text

    line = elem(grid.lines, grid.row)
    col = grid.col
    <<before::binary-size(^col), _::binary-size(^n), after_::binary>> = line
    line = <<before::binary, chunk::binary, after_::binary>>

    grid = %{
      grid
      | lines: put_elem(grid.lines, grid.row, line),
        col: grid.col + n,
        dirty: MapSet.put(grid.dirty, grid.row)
    }

    print(grid, rest)
  end

  defp line_feed(%{row: row, rows: rows} = grid) when row < rows - 1, do: %{grid | row: row + 1}

  # On the last row a line feed scrolls everything up by one.
  defp line_feed(grid) do
    lines =
      grid.lines
      |> Tuple.delete_at(0)
      |> Tuple.insert_at(grid.rows - 1, blank_line(grid.cols))

    %{grid | lines: lines, dirty: MapSet.new(0..(grid.rows - 1))}
  end

  defp blank_line(cols), do: :binary.copy(" ", cols)
end

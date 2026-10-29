defmodule Guiltty.Grid do
  @moduledoc """
  The screen as data: rows of cells, a cursor and the current *pen* (the
  style new text is written with).

  A cell is 10 bytes, and a row is one binary of `cols` cells:

      <<char::8, attrs::8, fg::32, bg::32>>

  `attrs` holds bit flags (see the `@bold` etc. below). A color is one of:

    * `0` - the default foreground or background
    * `0x01_0000NN` - palette index `NN` (0-255)
    * `0x02_RRGGBB` - a 24-bit color

  The renderer understands the same layout, so a row goes to it unchanged.
  The theme (which RGB each palette index and the defaults mean) is applied
  by the renderer.

  The cursor column may equal `cols`: the last cell was just written and the
  wrap is pending. The next printable character wraps; a CR or a cursor
  movement doesn't. xterm behaves the same way.
  """

  import Bitwise

  @cell_size 10

  # attrs bits
  @bold 0x01
  @dim 0x02
  @italic 0x04
  @underline 0x08
  @blink 0x10
  @inverse 0x20
  @hidden 0x40
  @strike 0x80

  @default_color 0

  defstruct [
    :cols,
    :rows,
    :lines,
    row: 0,
    col: 0,
    attrs: 0,
    fg: @default_color,
    bg: @default_color,
    cursor_visible: true,
    dirty: MapSet.new()
  ]

  @type t :: %__MODULE__{}
  @type color :: non_neg_integer()

  @tab_width 8

  def attr(:bold), do: @bold
  def attr(:dim), do: @dim
  def attr(:italic), do: @italic
  def attr(:underline), do: @underline
  def attr(:blink), do: @blink
  def attr(:inverse), do: @inverse
  def attr(:hidden), do: @hidden
  def attr(:strike), do: @strike

  @spec indexed(0..255) :: color()
  def indexed(n), do: 0x01_000000 ||| n

  @spec rgb(0..255, 0..255, 0..255) :: color()
  def rgb(r, g, b), do: 0x02_000000 ||| r <<< 16 ||| g <<< 8 ||| b

  def cell_size, do: @cell_size

  @spec new(pos_integer(), pos_integer()) :: t()
  def new(cols \\ 80, rows \\ 24) do
    grid = %__MODULE__{cols: cols, rows: rows}
    %{grid | lines: Tuple.duplicate(blank_line(grid, cols, @default_color), rows)} |> all_dirty()
  end

  ## Reading

  @doc "The cursor as `{row, col}`, clamped to a visible cell."
  def cursor(grid), do: {grid.row, min(grid.col, grid.cols - 1)}

  @doc "Returns `[{row_index, row}]` for changed rows and clears the dirty set."
  def take_dirty(grid) do
    rows = grid.dirty |> Enum.sort() |> Enum.map(&{&1, elem(grid.lines, &1)})
    {rows, %{grid | dirty: MapSet.new()}}
  end

  @doc "All rows as `[{row_index, row}]`, for a full redraw."
  def snapshot(grid), do: grid.lines |> Tuple.to_list() |> Enum.with_index(fn l, i -> {i, l} end)

  @doc "The screen as text, trailing spaces trimmed. For iex and tests."
  def dump(grid) do
    grid.lines
    |> Tuple.to_list()
    |> Enum.map_join("\n", &(&1 |> line_text() |> String.trim_trailing()))
  end

  @doc "The characters of one row."
  def line_text(line), do: for(<<c, _::binary-size(9) <- line>>, into: "", do: <<c>>)

  @doc "The cell at `{row, col}` as `{char, attrs, fg, bg}`."
  def cell(grid, row, col) do
    offset = col * @cell_size
    <<_::binary-size(^offset), c, attrs, fg::32, bg::32, _::binary>> = elem(grid.lines, row)
    {c, attrs, fg, bg}
  end

  ## Text

  @doc "Writes printable ASCII at the cursor with the current pen, wrapping at the right edge."
  def print(grid, <<>>), do: grid

  def print(%{col: col, cols: cols} = grid, text) when col >= cols do
    grid |> Map.put(:col, 0) |> index() |> print(text)
  end

  def print(grid, text) do
    n = min(grid.cols - grid.col, byte_size(text))
    <<chunk::binary-size(^n), rest::binary>> = text
    style = <<grid.attrs, grid.fg::32, grid.bg::32>>
    cells = for <<c <- chunk>>, into: <<>>, do: <<c, style::binary>>

    grid
    |> replace_cells(grid.row, grid.col, cells)
    |> Map.put(:col, grid.col + n)
    |> print(rest)
  end

  ## Cursor

  def carriage_return(grid), do: %{grid | col: 0}

  def backspace(grid), do: %{grid | col: max(min(grid.col, grid.cols - 1) - 1, 0)}

  def tab(grid) do
    next = (div(grid.col, @tab_width) + 1) * @tab_width
    %{grid | col: min(next, grid.cols - 1)}
  end

  @doc "Moves to `{row, col}`, clamped to the screen."
  def move_to(grid, row, col) do
    %{grid | row: clamp(row, 0, grid.rows - 1), col: clamp(col, 0, grid.cols - 1)}
  end

  @doc "Moves by a relative amount, stopping at the edges. Cancels a pending wrap."
  def move_by(grid, drow, dcol) do
    move_to(grid, grid.row + drow, min(grid.col, grid.cols - 1) + dcol)
  end

  def set_cursor_visible(grid, visible), do: %{grid | cursor_visible: visible}

  ## Scrolling

  @doc "Line feed: down one row, scrolling up at the bottom (IND)."
  def index(%{row: row, rows: rows} = grid) when row < rows - 1, do: %{grid | row: row + 1}
  def index(grid), do: scroll_up(grid, 1)

  @doc "Reverse index: up one row, scrolling down at the top (RI)."
  def reverse_index(%{row: row} = grid) when row > 0, do: %{grid | row: row - 1}
  def reverse_index(grid), do: scroll_down(grid, 1)

  @doc "Moves every row up by `n`; new rows at the bottom are blank."
  def scroll_up(grid, n) do
    n = min(n, grid.rows)
    kept = grid.lines |> Tuple.to_list() |> Enum.drop(n)
    new = List.duplicate(blank_line(grid, grid.cols, grid.bg), n)
    %{grid | lines: List.to_tuple(kept ++ new)} |> all_dirty()
  end

  @doc "Moves every row down by `n`; new rows at the top are blank."
  def scroll_down(grid, n) do
    n = min(n, grid.rows)
    kept = grid.lines |> Tuple.to_list() |> Enum.take(grid.rows - n)
    new = List.duplicate(blank_line(grid, grid.cols, grid.bg), n)
    %{grid | lines: List.to_tuple(new ++ kept)} |> all_dirty()
  end

  ## Erasing
  #
  # Erased cells take the current background color ("back color erase", the
  # `bce` capability in xterm-256color's terminfo entry), with no attributes.

  @doc "ED: 0 = cursor to end, 1 = start to cursor, 2 = everything."
  def erase_display(grid, 0) do
    grid = erase_line(grid, 0)
    Enum.reduce((grid.row + 1)..(grid.rows - 1)//1, grid, &blank_row(&2, &1))
  end

  def erase_display(grid, 1) do
    grid = erase_line(grid, 1)
    Enum.reduce(0..(grid.row - 1)//1, grid, &blank_row(&2, &1))
  end

  def erase_display(grid, 2), do: Enum.reduce(0..(grid.rows - 1), grid, &blank_row(&2, &1))
  def erase_display(grid, _mode), do: grid

  @doc "EL: 0 = cursor to end of line, 1 = start to cursor, 2 = whole line."
  def erase_line(grid, 0),
    do: blank_cells(grid, grid.row, min(grid.col, grid.cols - 1), grid.cols)

  def erase_line(grid, 1), do: blank_cells(grid, grid.row, 0, min(grid.col, grid.cols - 1) + 1)
  def erase_line(grid, 2), do: blank_row(grid, grid.row)
  def erase_line(grid, _mode), do: grid

  @doc "ECH: erases `n` cells from the cursor, without moving it."
  def erase_chars(grid, n) do
    from = min(grid.col, grid.cols - 1)
    blank_cells(grid, grid.row, from, min(from + n, grid.cols))
  end

  ## Pen

  def set_pen(grid, attrs, fg, bg), do: %{grid | attrs: attrs, fg: fg, bg: bg}

  ## Whole screen

  @doc "RIS: everything back to how a new grid starts."
  def reset(grid), do: new(grid.cols, grid.rows)

  @doc """
  Changes the size without reflowing text: rows are cut or padded on the
  right, and rows are added or removed at the bottom. When shrinking would
  push the cursor off the screen, rows go from the top instead, so the line
  you're typing on stays visible.
  """
  def resize(grid, cols, rows) do
    drop_top = max(grid.row - (rows - 1), 0)

    lines =
      grid.lines
      |> Tuple.to_list()
      |> Enum.drop(drop_top)
      |> Enum.take(rows)
      |> Enum.map(&fit_line(grid, &1, cols))

    padding = List.duplicate(blank_line(grid, cols, @default_color), rows - length(lines))

    %{grid | cols: cols, rows: rows, lines: List.to_tuple(lines ++ padding)}
    |> Map.put(:row, min(grid.row - drop_top, rows - 1))
    |> Map.put(:col, min(grid.col, cols - 1))
    |> all_dirty()
  end

  ## Helpers

  defp fit_line(grid, line, cols) do
    have = div(byte_size(line), @cell_size)

    if have >= cols,
      do: binary_part(line, 0, cols * @cell_size),
      else: line <> blank_line(grid, cols - have, @default_color)
  end

  defp blank_line(_grid, n, bg), do: :binary.copy(blank_cell(bg), n)
  defp blank_cell(bg), do: <<?\s, 0, @default_color::32, bg::32>>

  defp blank_row(grid, row), do: blank_cells(grid, row, 0, grid.cols)

  defp blank_cells(grid, _row, from, to) when from >= to, do: grid

  defp blank_cells(grid, row, from, to) do
    replace_cells(grid, row, from, :binary.copy(blank_cell(grid.bg), to - from))
  end

  defp replace_cells(grid, row, col, cells) do
    line = elem(grid.lines, row)
    start = col * @cell_size
    len = byte_size(cells)
    <<before::binary-size(^start), _::binary-size(^len), after_::binary>> = line
    line = <<before::binary, cells::binary, after_::binary>>
    %{grid | lines: put_elem(grid.lines, row, line), dirty: MapSet.put(grid.dirty, row)}
  end

  defp all_dirty(grid), do: %{grid | dirty: MapSet.new(0..(grid.rows - 1))}

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)
end

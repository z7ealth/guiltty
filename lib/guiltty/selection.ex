defmodule Guiltty.Selection do
  @moduledoc """
  The mouse selection: where it started (`anchor`), where the pointer is
  now (`head`), and how it grows. Positions are `{row_number, col}`, with
  row numbers as `Guiltty.Grid` counts them (scrollback included), so a
  selection stays on its text while output scrolls.

    * `:char` (one click, then drag) - from cell to cell
    * `:word` (double click) - whole words at both ends
    * `:line` (triple click) - whole rows
  """

  alias Guiltty.Grid

  defstruct [:anchor, :head, mode: :char]

  @type pos :: {integer(), non_neg_integer()}
  @type t :: %__MODULE__{anchor: pos(), head: pos(), mode: :char | :word | :line}

  # What ends a word on a double click, besides spaces.
  @delimiters ["\t", "\"", "'", "`", "(", ")", "[", "]", "{", "}", "<", ">", "|", ";", ",", "│"]

  def new(pos, clicks) do
    mode =
      case clicks do
        1 -> :char
        2 -> :word
        _ -> :line
      end

    %__MODULE__{anchor: pos, head: pos, mode: mode}
  end

  def extend(sel, pos), do: %{sel | head: pos}

  @doc "The selected cells as `{{row, col}, {row, col}}`, first to last, inclusive."
  def range(grid, sel) do
    {from, to} = Enum.min_max([sel.anchor, sel.head])

    case sel.mode do
      :char -> {from, to}
      :word -> {word_start(grid, from), word_end(grid, to)}
      :line -> {{elem(from, 0), 0}, {elem(to, 0), grid.cols - 1}}
    end
    |> whole_wide_chars(grid)
  end

  @doc "The columns selected in row `n`, as a range, or nil."
  def cols_in_row(grid, sel, n) do
    {{r1, c1}, {r2, c2}} = range(grid, sel)

    cond do
      n < r1 or n > r2 -> nil
      r1 == r2 -> c1..c2
      n == r1 -> c1..(grid.cols - 1)
      n == r2 -> 0..c2
      true -> 0..(grid.cols - 1)
    end
  end

  @doc """
  The selected text. Each row's trailing spaces are dropped and rows are
  joined with newlines.
  """
  def text(grid, sel) do
    {{r1, _}, {r2, _}} = range(grid, sel)

    r1..r2
    |> Enum.map(fn n ->
      case {Grid.line(grid, n), cols_in_row(grid, sel, n)} do
        {nil, _} ->
          ""

        {line, from..to//_} ->
          grid |> Grid.line_text(cells(line, from, to)) |> String.trim_trailing()
      end
    end)
    |> Enum.join("\n")
  end

  defp cells(line, from, to) do
    size = Grid.cell_size()
    binary_part(line, from * size, (to - from + 1) * size)
  end

  ## Words

  defp word_start(grid, {n, col}) do
    texts = texts(grid, n)
    class = class(Enum.at(texts, col))
    {n, scan(texts, col, -1, class)}
  end

  defp word_end(grid, {n, col}) do
    texts = texts(grid, n)
    class = class(Enum.at(texts, col))
    {n, scan(texts, col, 1, class)}
  end

  # Move from col while the neighbor is of the same class; a spacer (the
  # right half of a wide character) belongs to its left neighbor.
  defp scan(texts, col, step, class) do
    next = col + step

    if next >= 0 and next < length(texts) and
         (Enum.at(texts, next) == "" or class(Enum.at(texts, next)) == class),
       do: scan(texts, next, step, class),
       else: col
  end

  defp texts(grid, n) do
    case Grid.line(grid, n) do
      nil -> List.duplicate(" ", grid.cols)
      line -> for <<glyph::32, _::binary-size(10) <- line>>, do: Grid.glyph_text(grid, glyph)
    end
  end

  defp class(text) when text in [nil, " ", ""], do: :space
  defp class(text) when text in @delimiters, do: {:delimiter, text}
  defp class(_text), do: :word

  # Never select half of a wide character.
  defp whole_wide_chars({{r1, c1}, {r2, c2}}, grid) do
    c1 = if spacer?(grid, r1, c1), do: max(c1 - 1, 0), else: c1
    c2 = if wide?(grid, r2, c2), do: min(c2 + 1, grid.cols - 1), else: c2
    {{r1, c1}, {r2, c2}}
  end

  defp wide?(grid, n, col), do: has_attr?(grid, n, col, Grid.attr(:wide))
  defp spacer?(grid, n, col), do: has_attr?(grid, n, col, Grid.attr(:spacer))

  defp has_attr?(grid, n, col, bit) do
    case Grid.line(grid, n) do
      nil ->
        false

      line ->
        offset = col * Grid.cell_size()
        <<_::binary-size(^offset), _glyph::32, attrs::16, _::binary>> = line
        Bitwise.band(attrs, bit) != 0
    end
  end
end

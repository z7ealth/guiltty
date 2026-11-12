defmodule Guiltty.Url do
  @moduledoc """
  URLs in plain text: what Ctrl+click opens when no program marked the
  text as a link (OSC 8). `mix phx.server` printing
  `http://localhost:4000` is the usual case.

  As in Alacritty and Ghostty, it's a pattern over the text, not anything
  the program said: a scheme, then everything up to a space or a character
  that can't be in a URL. Punctuation at the end belongs to the sentence
  around it (`see https://x.y.`), and so does a closing bracket with no
  opening one in the URL (`(https://x.y)`).

  A URL longer than the row wraps onto the next ones, so the search runs
  over the whole *logical line*: rows joined where they wrapped (see
  "Reflow" in `Guiltty.Grid`).

      row 4 |Access at http://localhost:40|>   wrapped
      row 5 |00 now                       |
             -> "Access at http://localhost:4000 now"
             -> spans [{4, 10, 29}, {5, 0, 1}]

  Only the schemes guiltty would open are found: anything else isn't
  underlined, so it doesn't look clickable.
  """

  alias Guiltty.Grid

  import Bitwise

  # Alacritty's pattern, with only the schemes Window opens.
  @pattern ~r'(?:https?://|mailto:|file:)[^\x{00}-\x{1F}\x{7F}-\x{9F}<>"\s{|}^⟨⟩`\\]+'u
  # A URL in a paragraph rarely ends with these; a sentence often does.
  @trailing ~c".,:;!?'"
  # A logical line longer than this many rows isn't searched past it.
  @max_rows 16

  @typedoc "Row number (see `Guiltty.Grid`), first and last column."
  @type span :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @doc """
  The URL that covers row number `n`, column `col`, and the cells it takes,
  or nil.
  """
  @spec at(map(), integer(), non_neg_integer()) :: {binary(), [span()]} | nil
  def at(grid, n, col) do
    with line when is_binary(line) <- Grid.line(grid, n) do
      cells = grid |> logical_rows(n) |> Enum.flat_map(&cells(grid, &1)) |> with_offsets()
      text = Enum.map_join(cells, & &1.text)

      with %{offset: target} <- Enum.find(cells, &(&1.n == n and col in &1.c1..&1.c2)),
           {start, len} <- covering(text, target) do
        url = binary_part(text, start, len)
        {url, spans(cells, start, start + len)}
      else
        _ -> nil
      end
    end
  end

  @doc """
  Every URL that shows in rows `first` to `last` (row numbers), in reading
  order, each with the cells it takes: what the keyboard hints label. A
  URL that wrapped in from above the first row counts too.
  """
  @spec visible(map(), integer(), integer()) :: [{binary(), [span()]}]
  def visible(grid, first, last) do
    first
    |> Stream.unfold(fn
      n when n > last ->
        nil

      n ->
        rows = logical_rows(grid, n)
        {rows, rows.last + 1}
    end)
    |> Enum.flat_map(fn rows ->
      cells =
        rows
        |> Enum.filter(&Grid.line(grid, &1))
        |> Enum.flat_map(&cells(grid, &1))
        |> with_offsets()

      text = Enum.map_join(cells, & &1.text)

      for [{start, len}] <- Regex.scan(@pattern, text, return: :index),
          url = trim(binary_part(text, start, len)),
          not bare?(url),
          spans = spans(cells, start, start + byte_size(url)),
          Enum.any?(spans, fn {n, _, _} -> n in first..last//1 end),
          do: {url, spans}
    end)
    # A logical line longer than @max_rows can be met twice.
    |> Enum.uniq()
  end

  # The rows of the logical line through row n: up while the row above
  # wrapped, down while this one did.
  defp logical_rows(grid, n) do
    first = Enum.reduce_while(1..@max_rows, n, &up(grid, n - &1, &2))
    last = Enum.reduce_while(0..(@max_rows - 1), n, &down(grid, n + &1, &2))
    first..last
  end

  defp up(grid, above, acc) do
    case Grid.line(grid, above) do
      line when is_binary(line) -> if Grid.wrapped?(line), do: {:cont, above}, else: {:halt, acc}
      nil -> {:halt, acc}
    end
  end

  defp down(grid, n, acc) do
    case Grid.line(grid, n) do
      line when is_binary(line) ->
        if Grid.wrapped?(line) and Grid.line(grid, n + 1),
          do: {:cont, n + 1},
          else: {:halt, max(acc, n)}

      nil ->
        {:halt, acc}
    end
  end

  # One entry per cell that shows something; a wide character takes its
  # spacer's column too. `offset` is where its text starts, filled in below.
  defp cells(grid, n) do
    size = Grid.cell_size()
    wide = Grid.attr(:wide)

    for {<<glyph::32, attrs::16, _::binary-size(8)>>, col} <-
          Enum.with_index(for <<cell::binary-size(^size) <- Grid.line(grid, n)>>, do: cell),
        glyph != 0 do
      c2 = if (attrs &&& wide) != 0, do: col + 1, else: col
      %{n: n, c1: col, c2: c2, text: Grid.glyph_text(grid, glyph)}
    end
  end

  # Where each cell's text starts in the joined text, in bytes: what
  # Regex.scan's indexes are counted in.
  defp with_offsets(cells) do
    {cells, _} =
      Enum.map_reduce(cells, 0, fn cell, offset ->
        {Map.put(cell, :offset, offset), offset + byte_size(cell.text)}
      end)

    cells
  end

  # The match that holds byte `target`, trimmed of what belongs to the text
  # around it, as {start, length}.
  defp covering(text, target) do
    @pattern
    |> Regex.scan(text, return: :index)
    |> Enum.map(fn [{start, len}] -> {start, trim(binary_part(text, start, len))} end)
    |> Enum.find_value(fn {start, url} ->
      len = byte_size(url)
      if target >= start and target < start + len and not bare?(url), do: {start, len}
    end)
  end

  defp trim(url) do
    last = :binary.last(url)

    cond do
      last in @trailing -> url |> drop_last() |> trim()
      last == ?) and unbalanced?(url, "(", ")") -> url |> drop_last() |> trim()
      last == ?] and unbalanced?(url, "[", "]") -> url |> drop_last() |> trim()
      true -> url
    end
  end

  defp drop_last(url), do: binary_part(url, 0, byte_size(url) - 1)

  defp unbalanced?(url, open, close), do: count(url, close) > count(url, open)
  defp count(url, char), do: length(:binary.matches(url, char))

  # Only a scheme is left: "see http://." isn't a link.
  defp bare?(url), do: String.ends_with?(url, ["://", ":"])

  # The cells whose text lies in bytes from..to, as one span per row.
  defp spans(cells, from, to) do
    cells
    |> Enum.filter(&(&1.offset >= from and &1.offset < to))
    |> Enum.chunk_by(& &1.n)
    |> Enum.map(fn row -> {hd(row).n, hd(row).c1, List.last(row).c2} end)
  end
end

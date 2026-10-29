defmodule Guiltty.Terminal do
  @moduledoc """
  What the parser's commands *mean*: applies them to a `Guiltty.Grid`.

  MVP 2 understands:

  | Sequence           | Name   | Effect                                  |
  |--------------------|--------|-----------------------------------------|
  | CR LF BS HT        | C0     | the usual                               |
  | `CSI n A/B/C/D`    | CUU/CUD/CUF/CUB | cursor up/down/forward/back    |
  | `CSI n E/F`        | CNL/CPL | down/up n lines, to column 1           |
  | `CSI n G`, `CSI n \``| CHA/HPA | to column n                          |
  | `CSI n d`          | VPA    | to row n                                |
  | `CSI r;c H/f`      | CUP/HVP | to row r, column c (1-based)           |
  | `CSI n J`          | ED     | erase in display                        |
  | `CSI n K`          | EL     | erase in line                           |
  | `CSI n X`          | ECH    | erase n characters                      |
  | `CSI ... m`        | SGR    | colors and attributes (`Guiltty.SGR`)   |
  | `CSI ? 25 h/l`     | DECTCEM | show/hide the cursor                   |
  | `ESC D`, `ESC E`, `ESC M` | IND/NEL/RI | index, next line, reverse index |
  | `ESC c`            | RIS    | full reset                              |

  Anything else is ignored. Reverse index is listed for MVP 3, but `less`
  uses it to scroll back, so it's here already.
  """

  alias Guiltty.{Grid, Parser, SGR}

  @spec apply(Grid.t(), [Parser.command()]) :: Grid.t()
  def apply(grid, commands), do: Enum.reduce(commands, grid, &command/2)

  defp command({:print, text}, grid), do: Grid.print(grid, text)
  defp command(:cr, grid), do: Grid.carriage_return(grid)
  defp command(:lf, grid), do: Grid.index(grid)
  defp command(:bs, grid), do: Grid.backspace(grid)
  defp command(:ht, grid), do: Grid.tab(grid)

  defp command({:csi, nil, params, "", final}, grid), do: csi(final, params, grid)

  defp command({:csi, ??, params, "", final}, grid) when final in [?h, ?l],
    do: dec_mode(params, final == ?h, grid)

  defp command({:esc, "", ?D}, grid), do: Grid.index(grid)
  defp command({:esc, "", ?E}, grid), do: grid |> Grid.carriage_return() |> Grid.index()
  defp command({:esc, "", ?M}, grid), do: Grid.reverse_index(grid)
  defp command({:esc, "", ?c}, grid), do: Grid.reset(grid)

  defp command(_ignored, grid), do: grid

  ## CSI

  defp csi(?A, params, grid), do: Grid.move_by(grid, -count(params), 0)
  defp csi(?B, params, grid), do: Grid.move_by(grid, count(params), 0)
  defp csi(?C, params, grid), do: Grid.move_by(grid, 0, count(params))
  defp csi(?D, params, grid), do: Grid.move_by(grid, 0, -count(params))
  defp csi(?E, params, grid), do: grid |> Grid.move_by(count(params), 0) |> Grid.carriage_return()

  defp csi(?F, params, grid),
    do: grid |> Grid.move_by(-count(params), 0) |> Grid.carriage_return()

  defp csi(final, params, grid) when final in [?G, ?`],
    do: Grid.move_to(grid, grid.row, count(params) - 1)

  defp csi(?d, params, grid), do: Grid.move_to(grid, count(params) - 1, grid.col)

  defp csi(final, params, grid) when final in [?H, ?f] do
    Grid.move_to(grid, count(params, 0) - 1, count(params, 1) - 1)
  end

  defp csi(?J, params, grid), do: Grid.erase_display(grid, value(params, 0, 0))
  defp csi(?K, params, grid), do: Grid.erase_line(grid, value(params, 0, 0))
  defp csi(?X, params, grid), do: Grid.erase_chars(grid, count(params))
  defp csi(?m, params, grid), do: SGR.apply(grid, params)
  defp csi(_final, _params, grid), do: grid

  ## DEC private modes

  defp dec_mode(params, on?, grid) do
    Enum.reduce(params, grid, fn
      25, grid -> Grid.set_cursor_visible(grid, on?)
      # 1049 (alternate screen), 2004 (bracketed paste), 1 (cursor keys)...
      # come in MVP 3.
      _mode, grid -> grid
    end)
  end

  ## Parameters

  # A parameter that may carry sub-parameters (`38:5:1`): use the first.
  defp value(params, i, default) do
    case Enum.at(params, i) do
      nil -> default
      [first | _] -> first || default
      n -> n
    end
  end

  # Counts and positions: missing or 0 means 1.
  defp count(params, i \\ 0), do: max(value(params, i, 1), 1)
end

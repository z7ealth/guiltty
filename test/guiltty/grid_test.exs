defmodule Guiltty.GridTest do
  use ExUnit.Case, async: true

  alias Guiltty.Grid

  defp run(cmds, cols \\ 10, rows \\ 3), do: Grid.apply(Grid.new(cols, rows), cmds)

  test "prints and moves the cursor" do
    grid = run([{:print, "hi"}])
    assert Grid.dump(grid) == "hi\n\n"
    assert Grid.cursor(grid) == {0, 2}
  end

  test "CR LF starts a new line" do
    assert run([{:print, "a"}, :cr, :lf, {:print, "b"}]) |> Grid.dump() == "a\nb\n"
  end

  test "a full line wraps only when the next character arrives" do
    grid = run([{:print, "0123456789"}])
    assert Grid.cursor(grid) == {0, 9}
    assert grid |> Grid.apply([:cr, :lf, {:print, "x"}]) |> Grid.dump() == "0123456789\nx\n"
    assert run([{:print, "0123456789x"}]) |> Grid.dump() == "0123456789\nx\n"
  end

  test "a line feed on the last row scrolls up" do
    grid =
      run([
        {:print, "1"},
        :cr,
        :lf,
        {:print, "2"},
        :cr,
        :lf,
        {:print, "3"},
        :cr,
        :lf,
        {:print, "4"}
      ])

    assert Grid.dump(grid) == "2\n3\n4"
    assert Grid.cursor(grid) == {2, 1}
  end

  test "backspace stops at column 0 and tab stops at the last column" do
    assert run([:bs]) |> Grid.cursor() == {0, 0}
    assert run([{:print, "ab"}, :bs, {:print, "X"}]) |> Grid.dump() == "aX\n\n"
    assert run([:ht]) |> Grid.cursor() == {0, 8}
    assert run([:ht, :ht]) |> Grid.cursor() == {0, 9}
  end

  test "tracks dirty rows" do
    {rows, grid} = Grid.new(10, 3) |> Grid.take_dirty()
    assert length(rows) == 3
    {rows, _} = grid |> Grid.apply([:lf, {:print, "x"}]) |> Grid.take_dirty()
    assert rows == [{1, "x         "}]
  end
end

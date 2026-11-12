defmodule Guiltty.SelectionTest do
  @moduledoc "The text a selection copies: wrapped rows join, real line ends don't."
  use ExUnit.Case, async: true

  alias Guiltty.{Grid, Parser, Selection, Terminal}

  defp run(bytes, cols \\ 10, rows \\ 4) do
    {_p, cmds} = Parser.feed(Parser.new(), bytes)
    Terminal.apply(Grid.new(cols, rows), cmds)
  end

  defp text(grid, anchor, head),
    do: Selection.text(grid, %Selection{anchor: anchor, head: head})

  defp rows(grid, first, last), do: text(grid, {first, 0}, {last, grid.cols - 1})

  test "a line that only wrapped comes back as one line" do
    grid = run("0123456789abcdef\r\nnext")
    assert rows(grid, 0, 2) == "0123456789abcdef\nnext"
  end

  test "a space where the line wrapped is kept" do
    # "hello wor" plus a space fills the row exactly: the space is text.
    grid = run("hello wor ld")
    assert rows(grid, 0, 1) == "hello wor ld"
  end

  test "lines that ended with Enter keep their newline and lose trailing spaces" do
    grid = run("ab   \r\ncd")
    assert rows(grid, 0, 1) == "ab\ncd"
  end

  test "a selection that stops before the wrap mark keeps the newline" do
    grid = run("0123456789abcdef")
    assert text(grid, {0, 2}, {1, 3}) == "23456789abcd"

    assert Selection.text(grid, %Selection{anchor: {0, 0}, head: {1, 1}, mode: :line}) ==
             "0123456789abcdef"
  end

  test "a line wrapped from the scrollback joins too" do
    grid = run("0123456789abcdef\r\n1\r\n2\r\n3\r\n4")
    assert Grid.scrollback_size(grid) > 0
    assert rows(grid, 0, 1) == "0123456789abcdef"
  end
end

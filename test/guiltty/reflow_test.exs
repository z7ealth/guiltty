defmodule Guiltty.ReflowTest do
  @moduledoc "A new width rewraps the text. See Guiltty.Grid, \"Reflow\"."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Guiltty.{Grid, Parser, Terminal}

  defp run(bytes, cols \\ 10, rows \\ 5) do
    {_p, cmds} = Parser.feed(Parser.new(), bytes)
    Terminal.apply(Grid.new(cols, rows), cmds)
  end

  # All the text, scrollback and screen, with wrapped rows joined.
  defp text(grid) do
    grid.scrollback_first..(grid.history + grid.rows - 1)
    |> Enum.map(fn n ->
      line = Grid.line(grid, n)
      last = div(byte_size(line), 14) - 1
      <<_::binary-size(last * 14 + 4), attrs::16, _::binary>> = line
      {Grid.line_text(grid, line), Bitwise.band(attrs, Grid.attr(:wrapped)) != 0}
    end)
    |> Enum.chunk_while(
      "",
      fn
        {text, true}, acc -> {:cont, acc <> text}
        {text, false}, acc -> {:cont, acc <> String.trim_trailing(text), ""}
      end,
      fn acc -> {:cont, acc, ""} end
    )
    |> Enum.join("\n")
    |> String.trim_trailing("\n")
  end

  test "a long line splits when the window narrows" do
    grid = run("0123456789\r\nab") |> Grid.resize(4, 5)
    assert Grid.dump(grid) == "0123\n4567\n89\nab\n"
  end

  test "rows that wrapped join again when the window widens" do
    grid = run("0123456789abc\r\nde") |> Grid.resize(20, 5)
    assert Grid.dump(grid) == "0123456789abc\nde\n\n\n"
  end

  test "there and back gives the same screen" do
    grid = run("0123456789abc\r\nde")
    assert grid |> Grid.resize(4, 5) |> Grid.resize(10, 5) |> Grid.dump() == Grid.dump(grid)
  end

  test "a line that ended on its own stays ended, even a full one" do
    grid = run("0123456789\r\nab") |> Grid.resize(20, 5)
    assert Grid.dump(grid) == "0123456789\nab\n\n\n"
  end

  test "the cursor stays on the same character" do
    grid = run("0123456789abc") |> Grid.resize(20, 5)
    assert Grid.cursor(grid) == {0, 13}
    grid = run("0123456789abc\e[2;2H") |> Grid.resize(4, 5)
    # column 11 of the line: the "b"
    assert Grid.cursor(grid) == {2, 3}
    assert Grid.dump(grid) == "0123\n4567\n89ab\nc\n"
  end

  test "text pushed off the screen goes to the scrollback, and comes back" do
    grid = run("0123456789\r\nabcdefghij\r\nend") |> Grid.resize(4, 3)
    assert Grid.scrollback_size(grid) > 0
    assert Grid.dump(grid) |> String.ends_with?("end")
    back = Grid.resize(grid, 10, 5)
    assert Grid.dump(back) == "0123456789\nabcdefghij\nend\n\n"
    assert Grid.scrollback_size(back) == 0
  end

  test "blank rows below the text aren't text: they don't push it away" do
    grid = run("hi") |> Grid.resize(5, 5)
    assert Grid.dump(grid) == "hi\n\n\n\n"
    assert Grid.scrollback_size(grid) == 0
  end

  test "colors and attributes travel with the text" do
    grid = run("\e[1;31m0123456789ab\e[m") |> Grid.resize(20, 5)
    {_g, attrs, fg, _bg} = Grid.cell(grid, 0, 11)
    assert attrs == Grid.attr(:bold)
    assert fg == Grid.indexed(1)
  end

  test "a wide character never splits; the gap it leaves isn't text" do
    grid = run("abc日本") |> Grid.resize(4, 5)

    assert Grid.dump(grid) ==
             "abc\n日本\n\n\n\n" |> String.trim_trailing("\n") |> Kernel.<>("\n\n\n")

    back = Grid.resize(grid, 10, 5)
    assert Grid.dump(back) == "abc日本\n\n\n\n"
  end

  test "the scrollback is rewrapped too" do
    lines = Enum.map_join(1..10, "\r\n", &"line-#{&1}-0123456")
    grid = run(lines, 20, 3)
    before = text(grid)
    assert before |> String.split("\n") |> length() == 10
    assert text(Grid.resize(grid, 7, 3)) == before
    assert text(grid |> Grid.resize(7, 3) |> Grid.resize(33, 3)) == before
  end

  test "more text than the scrollback may keep drops the oldest" do
    {_p, cmds} = Parser.feed(Parser.new(), String.duplicate("0123456789", 30))
    grid = Terminal.apply(Grid.new(10, 3, scrollback: 5), cmds) |> Grid.resize(5, 3)
    assert Grid.scrollback_size(grid) == 5
  end

  test "rows keep working after a rewrap: scrolling, printing, the scrollback" do
    grid = run("0123456789abc") |> Grid.resize(4, 2)
    {_p, cmds} = Parser.feed(Parser.new(), "\r\nmore\r\nand more")
    grid = Terminal.apply(grid, cmds)
    assert Grid.dump(grid) |> String.contains?("more")
    assert Grid.line(grid, grid.scrollback_first) != nil
  end

  test "margins and the scroll region go back to the whole screen" do
    grid = run("\e[?69h\e[2;5s\e[2;3r") |> Grid.resize(20, 8)
    assert {grid.left, grid.right, grid.top, grid.bottom, grid.margins?} == {0, 19, 0, 7, false}
  end

  test "a prompt mark follows its row" do
    grid = run("0123456789abcd\r\n\e]133;A\a$ ")
    assert grid.prompt_marks == [2]
    assert Grid.resize(grid, 20, 5).prompt_marks == [1]
    assert Grid.resize(grid, 4, 5).prompt_marks == [4]
  end

  test "a link follows its text, even when it wraps" do
    grid = run("ab\e]8;;https://x.y\acdefgh\e]8;;\aij") |> Grid.resize(4, 5)
    assert Grid.dump(grid) == "abcd\nefgh\nij\n\n"
    assert Grid.link_at(grid, 0, 2) == "https://x.y"
    assert Grid.link_at(grid, 1, 3) == "https://x.y"
    assert Grid.link_at(grid, 2, 0) == nil
    assert Grid.link_at(grid, 0, 1) == nil
  end

  property "any width and back keeps the text, and never crashes" do
    check all(
            lines <- list_of(string(:ascii, max_length: 40), max_length: 30),
            width <- integer(1..50),
            rows <- integer(1..8),
            max_runs: 100
          ) do
      clean = Enum.map(lines, &String.replace(&1, ~r/[^ -~]/, "."))
      grid = run(Enum.join(clean, "\r\n"), 20, 5)
      expected = text(grid)
      resized = Grid.resize(grid, width, rows)
      assert text(resized) == expected
      {_row, col} = Grid.cursor(resized)
      assert col < width
      assert tuple_size(resized.lines) == rows
      assert text(Grid.resize(resized, 20, 5)) == expected
    end
  end
end

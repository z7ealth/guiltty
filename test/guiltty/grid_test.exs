defmodule Guiltty.GridTest do
  use ExUnit.Case, async: true

  alias Guiltty.{Grid, Parser, Terminal}

  # Feed bytes through the parser and the terminal, like the Screen does.
  defp run(bytes, cols \\ 10, rows \\ 3) do
    {_p, cmds} = Parser.feed(Parser.new(), bytes)
    Terminal.apply(Grid.new(cols, rows), cmds)
  end

  defp text(bytes, cols \\ 10, rows \\ 3), do: bytes |> run(cols, rows) |> Grid.dump()

  describe "text and C0" do
    test "prints and moves the cursor" do
      grid = run("hi")
      assert Grid.dump(grid) == "hi\n\n"
      assert Grid.cursor(grid) == {0, 2}
    end

    test "a full line wraps only when the next character arrives" do
      grid = run("0123456789")
      assert Grid.cursor(grid) == {0, 9}
      assert text("0123456789\r\nx") == "0123456789\nx\n"
      assert text("0123456789x") == "0123456789\nx\n"
    end

    test "a line feed on the last row scrolls up" do
      assert text("1\r\n2\r\n3\r\n4") == "2\n3\n4"
    end

    test "backspace and tab" do
      assert text("ab\bX") == "aX\n\n"
      assert run("\t") |> Grid.cursor() == {0, 8}
      assert run("\t\t") |> Grid.cursor() == {0, 9}
    end
  end

  describe "cursor movement" do
    test "CUP is 1-based and clamps" do
      assert run("\e[2;3H") |> Grid.cursor() == {1, 2}
      assert run("\e[H") |> Grid.cursor() == {0, 0}
      assert run("\e[99;99H") |> Grid.cursor() == {2, 9}
    end

    test "relative moves stop at the edges" do
      assert run("\e[2;5H\e[A") |> Grid.cursor() == {0, 4}
      assert run("\e[5A\e[20C") |> Grid.cursor() == {0, 9}
      assert run("\e[3;3H\e[2D\e[B") |> Grid.cursor() == {2, 0}
    end

    test "CHA, VPA, CNL, CPL" do
      assert run("abc\e[2G") |> Grid.cursor() == {0, 1}
      assert run("abc\e[3d") |> Grid.cursor() == {2, 3}
      assert run("abc\e[E") |> Grid.cursor() == {1, 0}
      assert run("\e[3;5H\e[2F") |> Grid.cursor() == {0, 0}
    end

    test "a cursor move cancels the pending wrap" do
      assert text("0123456789\e[1Gx") == "x123456789\n\n"
    end

    test "DECTCEM hides and shows the cursor" do
      refute run("\e[?25l").cursor_visible
      assert run("\e[?25l\e[?25h").cursor_visible
    end
  end

  describe "erasing" do
    test "EL" do
      assert text("abcdef\e[3G\e[K") == "ab\n\n"
      assert text("abcdef\e[3G\e[1K") == "   def\n\n"
      assert text("abcdef\e[2K") == "\n\n"
    end

    test "ED" do
      assert text("aaa\r\nbbb\r\nccc\e[2;2H\e[J") == "aaa\nb\n"
      assert text("aaa\r\nbbb\r\nccc\e[2;2H\e[1J") == "\n  b\nccc"
      assert text("aaa\r\nbbb\e[2J") == "\n\n"
    end

    test "ECH erases without moving" do
      grid = run("abcdef\e[2G\e[3X")
      assert Grid.dump(grid) == "a   ef\n\n"
      assert Grid.cursor(grid) == {0, 1}
    end

    test "erased cells take the current background (bce)" do
      grid = run("\e[44m\e[2J")
      assert {?\s, 0, 0, bg} = Grid.cell(grid, 2, 9)
      assert bg == Grid.indexed(4)
    end
  end

  describe "index and reverse index" do
    test "RI at the top scrolls down" do
      assert text("1\r\n2\r\n3\e[H\eMx") == "x\n1\n2"
    end

    test "NEL and IND" do
      assert run("ab\eEc") |> Grid.cursor() == {1, 1}
      assert run("ab\eDc") |> Grid.cursor() == {1, 3}
    end

    test "RIS resets everything" do
      grid = run("\e[31mabc\e[?25l\ec")
      assert Grid.dump(grid) == "\n\n"
      assert grid.cursor_visible
      assert grid.fg == 0
    end
  end

  describe "resize" do
    test "truncates and pads without reflow" do
      grid = run("0123456789\r\nab") |> Grid.resize(4, 4)
      assert Grid.dump(grid) == "0123\nab\n\n"
      assert Grid.dump(Grid.resize(grid, 6, 2)) == "0123\nab"
    end

    test "keeps the cursor's line when rows shrink" do
      grid = run("1\r\n2\r\n3") |> Grid.resize(10, 2)
      assert Grid.dump(grid) == "2\n3"
      assert Grid.cursor(grid) == {1, 1}
    end
  end

  test "tracks dirty rows" do
    {rows, grid} = Grid.new(10, 3) |> Grid.take_dirty()
    assert length(rows) == 3
    {_p, cmds} = Parser.feed(Parser.new(), "\nx")
    {rows, _} = grid |> Terminal.apply(cmds) |> Grid.take_dirty()
    assert [{1, row}] = rows
    assert Grid.line_text(row) == "x         "
  end
end

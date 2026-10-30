defmodule Guiltty.ScrollbackTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Guiltty.{Grid, Parser, Search, Selection, Terminal, View}

  defp run(bytes, cols \\ 10, rows \\ 3, opts \\ []) do
    {_p, cmds} = Parser.feed(Parser.new(), bytes)
    Terminal.apply(Grid.new(cols, rows, opts), cmds)
  end

  defp lines(n), do: Enum.map_join(1..n, "\r\n", &"line #{&1}")
  defp text(grid, n), do: grid |> Grid.line_text(Grid.line(grid, n)) |> String.trim_trailing()

  describe "scrollback" do
    test "rows scrolled off the top are kept, numbered from the first" do
      grid = run(lines(10))
      assert Grid.scrollback_size(grid) == 7
      assert text(grid, 0) == "line 1"
      assert text(grid, 6) == "line 7"
      # the screen continues the numbering
      assert text(grid, 7) == "line 8"
      assert Grid.dump(grid) == "line 8\nline 9\nline 10"
    end

    test "keeps at most scrollback_max rows, dropping the oldest" do
      grid = run(lines(10), 10, 3, scrollback: 4)
      assert Grid.scrollback_size(grid) == 4
      assert grid.scrollback_first == 3
      assert Grid.line(grid, 2) == nil
      assert text(grid, 3) == "line 4"
    end

    test "every 256 rows become a block, stored without trailing blanks" do
      grid = run(lines(300))
      assert map_size(grid.scrollback) == 1
      # 3 rows stay on the screen
      assert length(grid.recent) == 300 - 3 - 256
      {_starts, rows} = grid.scrollback[0]
      # "line 1" .. "line 9" are 6 cells, "line 10" .. "line 99" 7, the rest 8
      assert byte_size(rows) == (9 * 6 + 90 * 7 + 157 * 8) * Grid.cell_size()
      assert byte_size(Grid.line(grid, 0)) == 10 * Grid.cell_size()
      assert text(grid, 255) == "line 256"
      assert text(grid, 256) == "line 257"
    end

    test "old blocks are dropped as the limit moves past them" do
      grid = run(lines(1000), 10, 3, scrollback: 300)
      assert Grid.scrollback_size(grid) == 300
      assert Map.keys(grid.scrollback) |> Enum.sort() == [2]
      assert text(grid, grid.scrollback_first) == "line #{grid.scrollback_first + 1}"
    end

    test "the alternate screen and scroll regions don't add to it" do
      assert run("\e[?1049h" <> lines(10)) |> Grid.scrollback_size() == 0
      assert run("\e[1;2r" <> lines(10)) |> Grid.scrollback_size() == 0
    end

    test "ED 3 clears it" do
      assert run(lines(10) <> "\e[3J") |> Grid.scrollback_size() == 0
    end
  end

  describe "the view" do
    test "scrolled back, it starts in the scrollback; the cursor is out of view" do
      grid = run(lines(10))
      rows = View.rows(grid, 2, nil, nil)

      assert Enum.map(rows, fn {_i, l} -> grid |> Grid.line_text(l) |> String.trim() end) ==
               ["line 6", "line 7", "line 8"]

      assert View.cursor(grid, 0) == {2, 7}
      assert View.cursor(grid, 2) == nil
      assert View.clamp_scroll(grid, 100) == 7
    end

    test "marks the selection by flipping inverse, matches with match bits" do
      grid = run("hello world", 20)
      sel = Selection.new({grid.history, 0}, 1) |> Selection.extend({grid.history, 4})
      search = %{query: "world", match: {grid.history, 6, 10}}
      [{0, row} | _] = View.rows(grid, 0, sel, search)

      attrs = for <<_g::32, a::16, _::binary-size(8) <- row>>, do: a
      assert Enum.take(attrs, 5) |> Enum.all?(&((&1 &&& Grid.attr(:inverse)) != 0))
      assert Enum.at(attrs, 5) == 0
      assert (Enum.at(attrs, 6) &&& Grid.attr(:current_match)) != 0
    end
  end

  describe "selection" do
    test "by character, across rows, including the scrollback" do
      grid = run(lines(5))
      sel = Selection.new({1, 2}, 1) |> Selection.extend({3, 3})
      assert Selection.text(grid, sel) == "ne 2\nline 3\nline"
    end

    test "backwards is the same as forwards" do
      grid = run("abc def")
      n = grid.history
      a = Selection.new({n, 5}, 1) |> Selection.extend({n, 1})
      b = Selection.new({n, 1}, 1) |> Selection.extend({n, 5})
      assert Selection.text(grid, a) == Selection.text(grid, b)
    end

    test "a double click takes the word, a triple click the line" do
      grid = run("cd /tmp/x; ls", 20, 2)
      n = grid.history
      assert Selection.text(grid, Selection.new({n, 5}, 2)) == "/tmp/x"
      assert Selection.text(grid, Selection.new({n, 5}, 3)) == "cd /tmp/x; ls"
    end

    test "never takes half of a wide character" do
      grid = run("ab中文")
      n = grid.history
      sel = Selection.new({n, 3}, 1) |> Selection.extend({n, 4})
      assert Selection.text(grid, sel) == "中文"
    end
  end

  describe "search" do
    test "finds the newest match first, then older ones, then newer again" do
      grid = run("foo 1\r\nbar\r\nfoo 2\r\nfoo 3\r\nbaz")
      assert {3, 0, 2} = first = Search.find(grid, "foo", nil, :older)
      assert {2, 0, 2} = older = Search.find(grid, "foo", {3, 0}, :older)
      assert {0, 0, 2} = Search.find(grid, "foo", {2, 0}, :older)
      assert Search.find(grid, "foo", {0, 0}, :older) == nil
      assert Search.find(grid, "foo", {2, 0}, :newer) == first
      assert older
    end

    test "is smart about case" do
      grid = run("Hello hello", 20)
      assert Search.matches_in_row(grid, grid.history, "hello") == [{0, 4}, {6, 10}]
      assert Search.matches_in_row(grid, grid.history, "Hello") == [{0, 4}]
    end

    test "matches columns, not bytes, with wide characters" do
      grid = run("日本語 ok", 20, 2)
      assert Search.matches_in_row(grid, grid.history, "ok") == [{7, 8}]
      assert Search.matches_in_row(grid, grid.history, "本") == [{2, 2}]
    end
  end
end

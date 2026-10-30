defmodule Guiltty.UnicodeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias Guiltty.{Grid, Parser, Terminal, Unicode}

  doctest Guiltty.Unicode

  defp run(chunks, cols \\ 10, rows \\ 3) do
    {_p, grid} =
      Enum.reduce(List.wrap(chunks), {Parser.new(), Grid.new(cols, rows)}, fn chunk, {p, grid} ->
        {p, cmds} = Parser.feed(p, chunk)
        {p, Terminal.apply(grid, cmds)}
      end)

    grid
  end

  defp glyph_at(grid, row, col), do: grid |> Grid.cell(row, col) |> elem(0)
  defp attrs_at(grid, row, col), do: grid |> Grid.cell(row, col) |> elem(1)
  defp wide?(grid, row, col), do: (attrs_at(grid, row, col) &&& Grid.attr(:wide)) != 0
  defp spacer?(grid, row, col), do: (attrs_at(grid, row, col) &&& Grid.attr(:spacer)) != 0

  describe "widths agree with glibc's wcwidth" do
    test "for single characters" do
      assert Unicode.char_width(?a) == 1
      assert Unicode.char_width(0x301) == 0
      assert Unicode.char_width(?中) == 2
      assert Unicode.char_width(0x1F600) == 2
      assert Unicode.char_width(0x200D) == 0
    end

    test "a cluster is the sum, capped at 2" do
      assert Unicode.width("❤️") == 1
      assert Unicode.width("👍🏽") == 2
      assert Unicode.width("👨‍👩‍👧") == 2
    end
  end

  describe "wide characters" do
    test "take a cell and a spacer, and move the cursor two columns" do
      grid = run("中x")
      assert glyph_at(grid, 0, 0) == ?中 and wide?(grid, 0, 0)
      assert glyph_at(grid, 0, 1) == 0 and spacer?(grid, 0, 1)
      assert glyph_at(grid, 0, 2) == ?x
      assert Grid.cursor(grid) == {0, 3}
      assert Grid.dump(grid) == "中x\n\n"
    end

    test "one that doesn't fit in the last column wraps whole" do
      grid = run("123456789中")
      assert Grid.dump(grid) == "123456789\n中\n"
      assert Grid.cursor(grid) == {1, 2}
    end

    test "overwriting either half blanks the other half" do
      assert Grid.dump(run("中文\rx")) == "x 文\n\n"
      grid = run("中文\e[1Gx\e[2Gy")
      assert Grid.dump(grid) == "xy文\n\n"
      refute wide?(grid, 0, 0) or spacer?(grid, 0, 1)
    end

    test "inserting and deleting cells never leaves half a character" do
      # ICH pushes 文 past the edge; DCH removes the left half of 中.
      assert Grid.dump(run("12345678中\r\e[@")) == " 12345678\n\n"
      grid = run("中文\e[2G\e[P")
      assert Grid.dump(grid) == " 文\n\n"
      refute wide?(grid, 0, 0)
    end
  end

  describe "clusters" do
    test "several codepoints share one cell, with an id" do
      grid = run("é 🇯🇵")
      id = glyph_at(grid, 0, 0)
      assert id >= 0x110000 and grid.clusters[id] == "é"
      assert wide?(grid, 0, 2) and grid.clusters[glyph_at(grid, 0, 2)] == "🇯🇵"
      assert Grid.dump(grid) == "é 🇯🇵\n\n"
    end

    test "the same cluster gets the same id" do
      grid = run("e\u0301 e\u0301")
      assert glyph_at(grid, 0, 0) == glyph_at(grid, 0, 2)
      assert map_size(grid.clusters) == 1
    end

    test "a combining mark in the next read joins the character before it" do
      grid = run(["e", "́x"])
      assert Grid.dump(grid) == "éx\n\n"
      assert Grid.cursor(grid) == {0, 2}
    end

    test "half a flag in each read becomes one wide flag" do
      grid = run(["🇯", "🇵!"])
      assert Grid.dump(grid) == "🇯🇵!\n\n"
      assert wide?(grid, 0, 0)
    end

    test "regional indicators pair from the start of the run, however they arrive" do
      assert Grid.dump(run(["🇯", "🇯🇯"])) == Grid.dump(run("🇯🇯🇯"))
    end

    test "Grid.clusters_since lists the ones a viewer hasn't seen" do
      grid = run("e\u0301 🇯🇵")
      assert [{a, "é"}, {b, "🇯🇵"}] = Grid.clusters_since(grid, 0)
      assert Grid.clusters_since(grid, b) == [{b, "🇯🇵"}]
      assert Grid.clusters_since(grid, b + 1) == []
      assert a + 1 == b
    end
  end

  test "ls of Japanese and emoji names lines up (a real recording)" do
    bytes = File.read!(Path.expand("../fixtures/ls_unicode.bytes", __DIR__))
    grid = run(bytes, 80, 24)

    # ls measured every name with wcwidth and padded the columns; if guiltty
    # agrees, each name in row 1 starts where the name above it does.
    starts = fn row ->
      for col <- 1..79,
          glyph_at(grid, row, col - 1) == ?\s,
          glyph_at(grid, row, col) not in [?\s, 0],
          do: col
    end

    assert starts.(0) == [11, 24, 31, 43, 55]
    assert starts.(1) == [11, 24, 31, 43]
  end

  test "REP repeats a wide character" do
    assert Grid.dump(run("中\e[2b")) == "中中中\n\n"
  end

  property "any chunking of the same text gives the same screen" do
    pieces = StreamData.member_of(["a", "中", "😀", "é", "́", "🇯", "🇵", "👍🏽", " ", "\r\n", "\e[2D"])

    check all(
            parts <- list_of(pieces, max_length: 30),
            bytes = IO.iodata_to_binary(parts),
            cuts <- list_of(integer(0..max(byte_size(bytes), 1)), max_length: 6)
          ) do
      whole = run(bytes, 10, 4)
      chunked = run(split(bytes, cuts), 10, 4)
      assert Grid.dump(chunked) == Grid.dump(whole)
      assert Grid.cursor(chunked) == Grid.cursor(whole)
    end
  end

  defp split(bytes, cuts) do
    cuts
    |> Enum.map(&min(&1, byte_size(bytes)))
    |> Enum.uniq()
    |> Enum.sort()
    |> then(&([0] ++ &1 ++ [byte_size(bytes)]))
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> binary_part(bytes, a, b - a) end)
  end
end

defmodule Guiltty.PrintNifTest do
  # Text that isn't ASCII goes through the text NIF (Guiltty.Grid.print/2).
  # It's only allowed to be faster, never different: the grid must come
  # out exactly as Elixir alone makes it (Grid.print_in_elixir/2), cells,
  # cursor, scrollback, clusters and all, wherever the text starts, however
  # it wraps and however it's cut into prints.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Guiltty.Grid

  defp state(grid), do: Map.drop(Map.from_struct(grid), [:dirty, :blank])

  defp piece do
    StreamData.member_of([
      "a",
      "b",
      " ",
      "é",
      "ü",
      "✓",
      "→",
      "漢",
      "字",
      "🚀",
      "👍",
      # what joins: combining marks, a skin tone, ZWJ, VS16, flags, jamo,
      # a Devanagari conjunct
      "\u{0301}",
      "🏽",
      "\u{200D}",
      "\u{FE0F}",
      "\u{1F1EF}",
      "\u{1F1F5}",
      "\u{1100}",
      "\u{1161}",
      "क",
      "\u{094D}"
    ])
  end

  # A print's text: a few pieces (a run of one is the edge case).
  defp text,
    do: StreamData.map(StreamData.list_of(piece(), min_length: 1, max_length: 25), &Enum.join/1)

  property "printing through the NIF gives Elixir's grid" do
    check all(
            cols <- StreamData.integer(2..12),
            col <- StreamData.integer(0..(cols - 1)),
            insert <- StreamData.boolean(),
            attrs <- StreamData.member_of([0, Grid.attr(:bold), Grid.attr(:inverse)]),
            fg <- StreamData.member_of([0, Grid.indexed(3), Grid.rgb(9, 8, 7)]),
            before <- text(),
            prints <- StreamData.list_of(text(), min_length: 1, max_length: 4),
            max_runs: 1000
          ) do
      # Something on screen already, so a wide character can be cut in half.
      grid =
        Grid.new(cols, 4)
        |> Grid.print_in_elixir(before)
        |> Grid.move_to(2, col)
        |> Map.merge(%{insert: insert, attrs: attrs, fg: fg})

      nif = Enum.reduce(prints, grid, &Grid.print(&2, &1))
      elixir = Enum.reduce(prints, grid, &Grid.print_in_elixir(&2, &1))
      assert state(nif) == state(elixir)
    end
  end

  test "a wide character with one column left wraps whole" do
    grid = Grid.new(4, 2) |> Grid.print("ab")
    assert state(Grid.print(grid, "é漢")) == state(Grid.print_in_elixir(grid, "é漢"))
    assert Grid.dump(Grid.print(grid, "é漢")) == Grid.dump(Grid.print_in_elixir(grid, "é漢"))
  end

  test "a combining mark in the next print joins the character before it" do
    grid = Grid.new(10, 2) |> Grid.print("ñé")
    joined = Grid.print(grid, "\u{0301}x")
    assert state(joined) == state(Grid.print_in_elixir(grid, "\u{0301}x"))
    assert Grid.dump(joined) =~ "ñé\u{0301}x"
  end
end

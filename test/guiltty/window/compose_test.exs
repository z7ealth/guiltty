defmodule Guiltty.Window.ComposeTest do
  @moduledoc "v0.19: a tab's panes stitched into the one grid the renderer draws."
  use ExUnit.Case, async: true

  alias Guiltty.{Grid, Layout, Parser, Terminal}
  alias Guiltty.Window.Compose

  # A pane's Screen update, from text typed into a grid of its size.
  defp update(text, {w, h}) do
    {_p, cmds} = Parser.feed(Parser.new(), text)
    grid = Terminal.apply(Grid.new(w, h), cmds)

    %{
      size: {w, h},
      rows: Grid.snapshot(grid),
      clusters: Grid.clusters_since(grid, 0x110000),
      graphics: :same
    }
  end

  defp text(row), do: for(<<g::32, _::binary-size(10) <- row>>, into: "", do: <<g::utf8>>)

  # 1 | 2, in 21 x 4.
  defp two do
    layout = Layout.new(1) |> Layout.split(1, :right, 2)
    {rects, seps} = Layout.rects(layout, {0, 0, 21, 4})
    Compose.new({21, 4}, %{rects: rects, separators: seps, focus: 2}, Layout.panes(layout))
  end

  test "one pane: its rows are the window's, untouched" do
    c = Compose.new({10, 2}, %{rects: %{1 => {0, 0, 10, 2}}, separators: [], focus: 1}, [1])
    u = update("hello", {10, 2})
    {_c, changed, _} = Compose.update(c, 1, u)
    assert changed == u.rows
  end

  test "two panes side by side, with a separator between" do
    c = two()
    {c, _, _} = Compose.update(c, 1, update("left", {10, 4}))
    {c, changed, _} = Compose.update(c, 2, update("right", {10, 4}))
    assert [{0, row} | _] = changed
    assert text(row) == "left      │right     "
    assert {_, last} = List.last(Compose.all_rows(c))
    assert text(last) == "          │          "
  end

  test "the separator next to the focused pane is lit" do
    c = two()
    [{0, row} | _] = Compose.all_rows(c)
    <<_::binary-size(10 * 14), ?│::32, _attrs::16, fg::32, _::binary>> = row
    assert fg == Grid.indexed(4)
  end

  test "each pane's clusters get their own ids in the window" do
    c = two()
    {c, _, [{a, "👍🏽"}]} = Compose.update(c, 1, update("👍🏽", {10, 4}))
    {_c, changed, [{b, "👍🏾"}]} = Compose.update(c, 2, update("👍🏾", {10, 4}))
    assert a != b
    {0, row} = hd(changed)

    <<^a::32, _::binary-size(10), _::binary-size(9 * 14), _sep::binary-size(14), ^b::32,
      _::binary>> = row
  end

  test "what's under a cell: a pane with its own coordinates, or the separator" do
    c = two()
    assert Compose.at(c, 3, 1) == {:pane, 1, 3, 1}
    assert Compose.at(c, 10, 1) == :separator
    assert Compose.at(c, 12, 2) == {:pane, 2, 1, 2}
    assert Compose.cursor(c, 2, {1, 4}) == {1, 15}
  end

  test "a pane's rows for an old size are dropped" do
    {_c, changed, _} = Compose.update(two(), 1, update("old", {30, 4}))
    assert changed == []
  end

  test "images move with their pane, and are cut at its edges" do
    c = %{two() | cell_pixels: {10, 20}}
    pl = %{uid: 1, row: 0, col: 8, offset: {0, 0}, source: {0, 0, 40, 20}, cells: {0, 0}, z: 0}
    u = %{update("", {10, 4}) | graphics: {[pl], %{1 => %{}}}}
    {c, _, _} = Compose.update(c, 2, u)
    # Pane 2 starts at column 11; 40 px from its column 8 is 2 cells
    # inside it, then cut at its right edge.
    {[moved], _} = Compose.graphics(c)
    assert moved.col == 19 and moved.source == {0, 0, 20, 20}
  end
end

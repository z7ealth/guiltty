defmodule Guiltty.LayoutTest do
  @moduledoc "v0.19: split panes, as a tree of plain terms."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Guiltty.Layout

  # 1 | 2 over 3, in a 21 x 11 tab.
  defp three, do: Layout.new(1) |> Layout.split(1, :right, 2) |> Layout.split(2, :down, 3)

  test "splitting puts the new pane right of or below the old one" do
    assert three() ==
             {:split, :right, 0.5, {:pane, 1}, {:split, :down, 0.5, {:pane, 2}, {:pane, 3}}}

    assert Layout.panes(three()) == [1, 2, 3]
  end

  test "rects: panes share the room around one-cell separators" do
    {rects, seps} = Layout.rects(three(), {0, 0, 21, 11})
    assert rects == %{1 => {0, 0, 10, 11}, 2 => {11, 0, 10, 5}, 3 => {11, 6, 10, 5}}
    assert Enum.sort(seps) == [{:horizontal, 11, 5, 10}, {:vertical, 10, 0, 11}]
  end

  test "removing a pane gives its room to the other side" do
    assert Layout.remove(three(), 2) == {:split, :right, 0.5, {:pane, 1}, {:pane, 3}}
    assert Layout.remove(three(), 1) == {:split, :down, 0.5, {:pane, 2}, {:pane, 3}}
    assert Layout.remove(Layout.new(1), 1) == nil
  end

  test "the neighbor in each direction, by where the panes are" do
    {rects, _} = Layout.rects(three(), {0, 0, 21, 11})
    assert Layout.neighbor(rects, 1, :right) in [2, 3]
    assert Layout.neighbor(rects, 2, :left) == 1
    assert Layout.neighbor(rects, 3, :left) == 1
    assert Layout.neighbor(rects, 2, :down) == 3
    assert Layout.neighbor(rects, 3, :up) == 2
    assert Layout.neighbor(rects, 1, :left) == nil
    assert Layout.neighbor(rects, 2, :up) == nil
  end

  test "resize moves the nearest separator across that direction, like tmux" do
    size = {21, 11}
    # 2 is right of the vertical separator: :right moves it right, 2 shrinks.
    {rects, _} = Layout.rects(Layout.resize(three(), 2, :right, 3, size), {0, 0, 21, 11})
    assert {11 + 3, 0, 10 - 3, 5} == rects[2]
    assert {0, 0, 13, 11} == rects[1]

    # 2 is above the horizontal one: :down grows it.
    {rects, _} = Layout.rects(Layout.resize(three(), 2, :down, 2, size), {0, 0, 21, 11})
    assert {11, 0, 10, 7} == rects[2] and {11, 8, 10, 3} == rects[3]

    # 1 has no horizontal separator anywhere around it: nothing moves.
    assert Layout.resize(three(), 1, :down, 2, size) == three()
  end

  test "a separator can't push a pane below one cell" do
    {rects, _} = Layout.rects(Layout.resize(three(), 1, :left, 50, {21, 11}), {0, 0, 21, 11})
    assert {0, 0, 1, 11} == rects[1]
  end

  test "too small to split: every pane still gets a size, the first shows" do
    {rects, seps} = Layout.rects(three(), {0, 0, 2, 11})
    assert seps == []
    assert Enum.all?(Map.values(rects), fn {_, _, w, h} -> w >= 1 and h >= 1 end)
  end

  property "panes and separators cover every cell of the tab, and nothing outside it" do
    check all(
            ops <- list_of({member_of([:right, :down]), integer(0..20)}, max_length: 8),
            w <- integer(3..80),
            h <- integer(3..40)
          ) do
      tree =
        Enum.reduce(ops, {Layout.new(0), 1}, fn {dir, pick}, {tree, next} ->
          panes = Layout.panes(tree)
          {Layout.split(tree, Enum.at(panes, rem(pick, length(panes))), dir, next), next + 1}
        end)
        |> elem(0)

      {rects, seps} = Layout.rects(tree, {0, 0, w, h})
      assert Map.keys(rects) |> Enum.sort() == Layout.panes(tree) |> Enum.sort()

      cells =
        for {_id, {x, y, rw, rh}} <- rects,
            # a pane with no room for itself shares its sibling's rect, hidden
            rw >= 1 and rh >= 1,
            cx <- x..(x + rw - 1),
            cy <- y..(y + rh - 1),
            do: {cx, cy}

      sep_cells =
        Enum.flat_map(seps, fn
          {:vertical, x, y, sh} -> for cy <- y..(y + sh - 1), do: {x, cy}
          {:horizontal, x, y, sw} -> for cx <- x..(x + sw - 1), do: {cx, y}
        end)

      everything = MapSet.new(cells ++ sep_cells)
      assert Enum.all?(everything, fn {cx, cy} -> cx in 0..(w - 1) and cy in 0..(h - 1) end)
      # Every cell of the tab is covered.
      assert MapSet.size(everything) == w * h
    end
  end
end

defmodule Guiltty.SGRTest do
  use ExUnit.Case, async: true

  alias Guiltty.{Grid, Parser, Terminal}

  defp pen(bytes) do
    {_p, cmds} = Parser.feed(Parser.new(), bytes)
    grid = Terminal.apply(Grid.new(10, 2), cmds)
    {grid.attrs, grid.fg, grid.bg}
  end

  defp attrs(names), do: names |> Enum.map(&Grid.attr/1) |> Enum.reduce(0, &Bitwise.bor/2)

  test "attributes on and off" do
    assert pen("\e[1;4;7m") == {attrs([:bold, :underline, :inverse]), 0, 0}
    assert pen("\e[1;2;3;4;5;7;8;9m") |> elem(0) == 0xFF
    assert pen("\e[1;2m\e[22m") == {0, 0, 0}
    assert pen("\e[4m\e[24m\e[7m\e[27m") == {0, 0, 0}
    assert pen("\e[21m") |> elem(0) == attrs([:underline])
  end

  test "reset with 0 or nothing" do
    assert pen("\e[1;31;42m\e[0m") == {0, 0, 0}
    assert pen("\e[1;31;42m\e[m") == {0, 0, 0}
  end

  test "16 colors" do
    assert pen("\e[31;42m") == {0, Grid.indexed(1), Grid.indexed(2)}
    assert pen("\e[91;102m") == {0, Grid.indexed(9), Grid.indexed(10)}
    assert pen("\e[31;42m\e[39;49m") == {0, 0, 0}
  end

  test "256 colors" do
    assert pen("\e[38;5;208;48;5;17m") == {0, Grid.indexed(208), Grid.indexed(17)}
    assert pen("\e[38:5:208m") |> elem(1) == Grid.indexed(208)
  end

  test "truecolor in every form" do
    color = Grid.rgb(255, 128, 0)
    assert pen("\e[38;2;255;128;0m") |> elem(1) == color
    assert pen("\e[48:2::255:128:0m") |> elem(2) == color
    assert pen("\e[38:2:255:128:0m") |> elem(1) == color
  end

  test "sequences combine and values are clamped" do
    assert pen("\e[1;38;5;100;4m") == {attrs([:bold, :underline]), Grid.indexed(100), 0}
    assert pen("\e[38;2;999;0;0m") |> elem(1) == Grid.rgb(255, 0, 0)
  end

  test "colon underline styles" do
    assert pen("\e[4:3m") |> elem(0) == attrs([:underline])
    assert pen("\e[4m\e[4:0m") |> elem(0) == 0
  end

  test "printed cells carry the pen" do
    {_p, cmds} = Parser.feed(Parser.new(), "\e[1;31mR\e[0mn")
    grid = Terminal.apply(Grid.new(10, 2), cmds)
    assert Grid.cell(grid, 0, 0) == {?R, attrs([:bold]), Grid.indexed(1), 0}
    assert Grid.cell(grid, 0, 1) == {?n, 0, 0, 0}
  end
end

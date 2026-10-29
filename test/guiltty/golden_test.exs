defmodule Guiltty.GoldenTest do
  @moduledoc """
  Golden tests: real bytes recorded from real programs (see
  test/fixtures/record.sh) go through the parser and the terminal at 80x24,
  and the resulting screen is compared to a saved snapshot.

  A snapshot (`NAME.txt`) has the screen text, then every run of styled
  cells. To rewrite them after an intended change:

      GUILTTY_UPDATE_GOLDEN=1 mix test test/guiltty/golden_test.exs

  and review the diff before committing it.
  """

  use ExUnit.Case, async: true

  import Bitwise

  alias Guiltty.{Grid, Parser, Terminal}

  @fixtures Path.wildcard(Path.expand("../fixtures/*.bytes", __DIR__))
  @update System.get_env("GUILTTY_UPDATE_GOLDEN") == "1"

  for path <- @fixtures do
    name = Path.basename(path, ".bytes")
    @path path

    test "#{name} matches its snapshot" do
      actual = @path |> File.read!() |> render() |> snapshot()
      expected_path = Path.rootname(@path) <> ".txt"

      if @update or not File.exists?(expected_path) do
        File.write!(expected_path, actual)
      end

      assert actual == File.read!(expected_path)
    end

    test "#{name} renders the same when fed one byte at a time" do
      bytes = File.read!(@path)
      assert snapshot(render_bytewise(bytes)) == snapshot(render(bytes))
    end
  end

  test "there are at least 10 fixtures" do
    assert length(@fixtures) >= 10
  end

  defp render(bytes) do
    {_p, cmds} = Parser.feed(Parser.new(), bytes)
    Terminal.apply(Grid.new(80, 24), cmds)
  end

  defp render_bytewise(bytes) do
    {_p, grid} =
      for <<byte <- bytes>>, reduce: {Parser.new(), Grid.new(80, 24)} do
        {p, grid} ->
          {p, cmds} = Parser.feed(p, <<byte>>)
          {p, Terminal.apply(grid, cmds)}
      end

    grid
  end

  @doc false
  def snapshot(grid) do
    {row, col} = Grid.cursor(grid)

    """
    #{Grid.dump(grid)}
    --- cursor #{row},#{col} #{if grid.cursor_visible, do: "visible", else: "hidden"}
    --- styles
    #{styles(grid)}\
    """
  end

  # One line per run of identical, non-default cells: "row col-col style".
  defp styles(grid) do
    for row <- 0..(grid.rows - 1),
        {style, from, to} <- runs(grid, row),
        style != {0, 0, 0},
        into: "",
        do: "#{row} #{from}-#{to} #{describe(style)}\n"
  end

  defp runs(grid, row) do
    grid.lines
    |> elem(row)
    |> then(&for(<<_c, attrs, fg::32, bg::32 <- &1>>, do: {attrs, fg, bg}))
    |> Enum.with_index()
    |> Enum.chunk_by(fn {style, _col} -> style end)
    |> Enum.map(fn [{style, from} | _] = run -> {style, from, from + length(run) - 1} end)
  end

  defp describe({attrs, fg, bg}) do
    names =
      for name <- [:bold, :dim, :italic, :underline, :blink, :inverse, :hidden, :strike],
          (attrs &&& Grid.attr(name)) != 0,
          do: Atom.to_string(name)

    Enum.join(names ++ color("fg", fg) ++ color("bg", bg), " ")
  end

  defp color(_which, 0), do: []
  defp color(which, c) when c >>> 24 == 1, do: ["#{which}=#{c &&& 0xFF}"]

  defp color(which, c),
    do: ["#{which}=##{(c &&& 0xFFFFFF) |> Integer.to_string(16) |> String.pad_leading(6, "0")}"]
end

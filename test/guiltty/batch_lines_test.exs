defmodule Guiltty.BatchLinesTest do
  # Lines of text get a fast path (Guiltty.Grid.print_lines/2): laid down
  # together and scrolled once. It's only allowed to be faster, never
  # different: the grid must come out exactly as if each command ran on
  # its own (the slow path), screen, scrollback, cursor and all.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Guiltty.{Grid, Parser, Terminal}

  # Everything that describes what's on screen and in the scrollback. Not
  # `dirty` (which rows to send: the fast path marks them all) nor the
  # cached blank line.
  defp state(grid), do: Map.drop(Map.from_struct(grid), [:dirty, :blank])

  defp both_ways(bytes, cols, rows, opts) do
    {_p, commands} = Parser.feed(Parser.new(), bytes)
    grid = Grid.new(cols, rows, opts)
    fast = Terminal.apply(grid, commands)
    # One command at a time: a list of one is never a batch.
    slow = Enum.reduce(commands, grid, &Terminal.apply(&2, [&1]))
    {fast, slow}
  end

  defp line do
    StreamData.one_of([
      # plain, sometimes with trailing spaces
      StreamData.string(:alphanumeric, max_length: 20) |> StreamData.map(&(&1 <> "  ")),
      StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
      # too long for the row: it wraps
      StreamData.string(:alphanumeric, min_length: 25, max_length: 40),
      # not ASCII
      StreamData.member_of(["日本", "é", "👍🏽 ok", "ñ"]),
      # colors and attributes before or after
      StreamData.map(StreamData.string(:alphanumeric, max_length: 10), &"\e[1;31m#{&1}\e[0m"),
      StreamData.map(StreamData.string(:alphanumeric, max_length: 10), &"\e[7m#{&1} "),
      # not a whole line: the next one starts mid-row
      StreamData.constant("partial")
    ])
  end

  property "printing lines in a batch gives exactly the grid of one by one" do
    check all(
            lines <- StreamData.list_of(line(), max_length: 60),
            endings <-
              StreamData.list_of(StreamData.member_of(["\r\n", "\r\n", "\n", ""]),
                length: length(lines)
              ),
            start <- StreamData.member_of(["", "\e[2;4r", "\e[?1049h", "\e(0", "\e[4h", "\e[44m"]),
            scrollback <- StreamData.member_of([0, 5, 300]),
            max_runs: 500
          ) do
      bytes = start <> Enum.join(Enum.zip_with(lines, endings, &(&1 <> &2)))
      {fast, slow} = both_ways(bytes, 20, 6, scrollback: scrollback)
      assert state(fast) == state(slow)
    end
  end

  test "a long stream fills the scrollback the same way" do
    bytes = for n <- 1..2_000, into: "", do: "line #{n}   \r\n"
    {fast, slow} = both_ways(bytes, 30, 10, scrollback: 700)
    assert state(fast) == state(slow)
    assert Grid.dump(fast) == Grid.dump(slow)
  end
end

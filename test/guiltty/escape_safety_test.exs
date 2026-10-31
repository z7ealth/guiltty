defmodule Guiltty.EscapeSafetyTest do
  @moduledoc """
  MVP 12: what a program (or a server at the other end of ssh) can make
  guiltty do by printing bytes. The classic attacks make the terminal
  type something back: an answer that echoes the program's own data
  (the title, a string it sent) becomes a command at the shell's prompt.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Guiltty.{Grid, Parser, Terminal}

  defp run(bytes, cols \\ 20, rows \\ 5) do
    {_p, cmds} = Parser.feed(Parser.new(), bytes)
    Terminal.apply(Grid.new(cols, rows), cmds)
  end

  # Escape sequences, mostly real ones and their neighbors, with random
  # parameters and strings: that reaches far more of the terminal than
  # plain random bytes, which rarely form a sequence.
  defp sequence do
    params = StreamData.list_of(StreamData.integer(0..70_000), max_length: 6)

    StreamData.one_of([
      StreamData.bind(params, fn ps ->
        StreamData.bind(StreamData.member_of(["", "?", ">", "=", "!", " "]), fn mark ->
          StreamData.map(StreamData.integer(0x40..0x7E), fn final ->
            "\e[" <> mark <> Enum.join(ps, ";") <> <<final>>
          end)
        end)
      end),
      StreamData.map(StreamData.binary(max_length: 40), &("\e]" <> &1 <> "\a")),
      StreamData.map(StreamData.binary(max_length: 40), &("\eP" <> &1 <> "\e\\")),
      StreamData.map(StreamData.binary(max_length: 40), &("\e]0;" <> &1 <> "\e\\")),
      StreamData.map(StreamData.integer(0x20..0x7E), &<<0x1B, &1>>),
      StreamData.binary(max_length: 20)
    ])
  end

  property "answers are only ever the fixed ones, never the program's data" do
    check all(seqs <- StreamData.list_of(sequence(), max_length: 30), max_runs: 1000) do
      {answers, _grid} = seqs |> Enum.join() |> run() |> Grid.take_responses()

      for answer <- answers do
        assert answer in ["\e[?62;22c", "\e[>1;10;0c", "\e[0n"] or
                 answer =~ ~r/\A\e\[\d{1,4};\d{1,4}R\z/,
               "unexpected answer #{inspect(answer)}"
      end
    end
  end

  property "a title is short, valid UTF-8, and has no controls or markers" do
    check all(text <- StreamData.binary(max_length: 600), max_runs: 1000) do
      title = run("\e]2;" <> text <> "\a").title || ""
      assert String.valid?(title)
      assert byte_size(title) <= 256
      refute title =~ ~r/[\x{00}-\x{1f}\x{7f}-\x{9f}\x{202a}-\x{202e}\x{2066}-\x{2069}]/u
    end
  end

  test "a title can't wear guiltty's markers or reorder itself" do
    title = run("\e]0;📡 prod 🔒\u{202E}lmth.exe\a").title
    assert title == "prod lmth.exe"
  end

  test "one short sequence can't make the screen do unbounded work" do
    # REP (repeat the last character) with the largest count: at most a
    # screenful is printed, however big the number.
    {time, grid} = :timer.tc(fn -> run("x\e[65535b") end)
    assert time < 1_000_000
    assert Grid.dump(grid) |> String.replace(~r/\s/, "") |> String.length() <= 20 * 5
  end
end

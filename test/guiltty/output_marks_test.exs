defmodule Guiltty.OutputMarksTest do
  @moduledoc """
  Where a command's output is (OSC 133 C and D), for copying it. The bytes
  are what a shell with integration sends: the prompt (A), the command line,
  Enter, then C before the command runs and D after it exits.
  """
  use ExUnit.Case, async: true

  alias Guiltty.{Grid, Parser, Selection, Terminal}

  defp run(bytes, cols \\ 20, rows \\ 6, opts \\ []) do
    {_p, cmds} = Parser.feed(Parser.new(), bytes)
    Terminal.apply(Grid.new(cols, rows, opts), cmds)
  end

  defp output_text(grid) do
    case Grid.last_output(grid) do
      {first, last} ->
        Selection.text(grid, %Selection{anchor: {first, 0}, head: {last, grid.cols - 1}})

      other ->
        other
    end
  end

  defp command(cmd, output, d \\ "\e]133;D;0\a"),
    do: "\e]133;A\a$ #{cmd}\r\n\e]133;C\a#{output}#{d}"

  test "the last command's output, between C and D" do
    grid = run(command("ls", "a\r\nb\r\n") <> command("echo hi", "hi\r\n") <> "\e]133;A\a$ ")
    assert output_text(grid) == "hi"
  end

  test "output without a final newline ends on the cursor's row" do
    grid = run(command("printf x", "one\r\ntwo") <> "\r\n\e]133;A\a$ ")
    assert output_text(grid) == "one\ntwo"
  end

  test "a shell that sends no D: the next prompt ends it" do
    grid = run(command("ls", "a\r\nb\r\n", "") <> "\e]133;A\a$ ")
    assert output_text(grid) == "a\nb"
  end

  test "a command still running: what it printed so far" do
    grid = run(command("make", "cc a.c\r\ncc b", ""))
    assert output_text(grid) == "cc a.c\ncc b"
  end

  test "a command that printed nothing, and a shell that marks nothing" do
    assert Grid.last_output(run(command("true", ""))) == :empty
    assert Grid.last_output(run("$ ls\r\na\r\n$ ")) == nil
    # One prompt alone says nothing about output.
    assert Grid.last_output(run("\e]133;A\a$ ls\r\na\r\n")) == nil
  end

  test "a shell that marks only prompts: the rows between them, less the command" do
    grid = run("\e]133;A\a$ ls\r\na\r\nb\r\n\e]133;A\a$ ")
    assert Grid.last_output(grid) == {:guess, {1, 2}}
    assert Grid.last_output(run("\e]133;A\a$ true\r\n\e]133;A\a$ ")) == :empty
  end

  test "a guessed command line that wrapped is left out whole" do
    long = String.duplicate("x", 25)
    grid = run("\e]133;A\a$ echo #{long}\r\n#{long}\r\n\e]133;A\a$ ")
    assert {:guess, {first, last}} = Grid.last_output(grid)
    text = Selection.text(grid, %Selection{anchor: {first, 0}, head: {last, grid.cols - 1}})
    assert text == long
  end

  test "output longer than the screen comes from the scrollback" do
    lines = Enum.map_join(1..30, "", &"#{&1}\r\n")
    grid = run(command("seq 30", lines) <> "\e]133;A\a$ ")
    assert output_text(grid) == Enum.map_join(1..30, "\n", &to_string/1)
  end

  test "only what the scrollback still holds" do
    lines = Enum.map_join(1..30, "", &"#{&1}\r\n")
    grid = run(command("seq 30", lines) <> "\e]133;A\a$ ", 20, 6, scrollback: 10)
    text = output_text(grid)
    assert String.ends_with?(text, "\n30")
    refute String.starts_with?(text, "1\n")
  end

  test "marks made on the alternate screen are ignored" do
    grid = run(command("ls", "a\r\n") <> "\e[?1049h\e]133;C\aVIM\e]133;D\a\e[?1049l")
    assert output_text(grid) == "a"
  end

  test "clearing the scrollback forgets output that started in it" do
    lines = Enum.map_join(1..30, "", &"#{&1}\r\n")
    grid = run(command("seq 30", lines) <> "\e]133;A\a$ \e[3J")
    assert Grid.last_output(grid) == nil
  end

  test "the output follows its rows when the width changes" do
    grid = run(command("cat", "0123456789abcdefghij0123\r\n") <> "\e]133;A\a$ ")
    # The line wrapped, so it copies whole at any width.
    assert output_text(grid) == "0123456789abcdefghij0123"
    wide = Grid.resize(grid, 30, 6)
    assert output_text(wide) == "0123456789abcdefghij0123"
    narrow = Grid.resize(grid, 8, 6)
    assert output_text(narrow) == "0123456789abcdefghij0123"
  end

  describe "commands starting and ending" do
    test "D's exit code comes out, after the start" do
      grid = run(command("false", "", "\e]133;D;1\a"))
      assert {[:started, {:ended, 1}], grid} = Grid.take_commands(grid)
      assert {[], _} = Grid.take_commands(grid)
    end

    test "a D with options after the code, and a D with no code" do
      assert {[:started, {:ended, 0}], _} =
               Grid.take_commands(run(command("ls", "", "\e]133;D;0;aid=7\a")))

      assert {[:started, {:ended, nil}], _} =
               Grid.take_commands(run(command("ls", "", "\e]133;D\a")))
    end

    test "a D before any command (fish sends one at startup) is no command" do
      assert {[], _} = Grid.take_commands(run("\e]133;D;0\a\e]133;A\a$ "))
    end
  end
end

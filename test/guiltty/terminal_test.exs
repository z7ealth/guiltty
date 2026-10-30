defmodule Guiltty.TerminalTest do
  @moduledoc "MVP 3: the screen features full-screen programs rely on."
  use ExUnit.Case, async: true

  alias Guiltty.{Grid, Parser, Terminal}

  defp run(bytes, cols \\ 10, rows \\ 5, grid \\ nil) do
    {_p, cmds} = Parser.feed(Parser.new(), bytes)
    Terminal.apply(grid || Grid.new(cols, rows), cmds)
  end

  defp text(bytes, cols \\ 10, rows \\ 5), do: bytes |> run(cols, rows) |> Grid.dump()
  defp first_line(bytes), do: bytes |> text() |> String.split("\n") |> hd()

  defp responses(bytes) do
    {resp, _grid} = bytes |> run() |> Grid.take_responses()
    Enum.join(resp)
  end

  describe "alternate screen" do
    test "1049 saves the cursor, switches to a blank screen, and restores both" do
      # The cursor doesn't move on the way in (xterm doesn't either); programs
      # position it themselves before drawing.
      grid = run("shell\r\nprompt$ \e[?1049hfull screen app")
      assert grid.alt?
      assert Grid.dump(grid) == "\n        fu\nll screen\napp\n"

      grid = run("\e[?1049l", 10, 5, grid)
      refute grid.alt?
      assert Grid.dump(grid) == "shell\nprompt$\n\n\n"
      assert Grid.cursor(grid) == {1, 8}
    end

    test "1047 clears the alternate screen on entry, 47 doesn't" do
      grid = run("\e[?47hone\e[?47l\e[?47h")
      assert Grid.dump(grid) =~ "one"
      grid = run("\e[?1047hone\e[?1047l\e[?1047h")
      refute Grid.dump(grid) =~ "one"
    end

    test "entering twice doesn't lose the main screen" do
      grid = run("main\e[?1049h\e[?1049hx\e[?1049l")
      assert Grid.dump(grid) =~ "main"
    end
  end

  describe "cursor save and restore" do
    test "DECSC/DECRC keep position and pen" do
      grid = run("\e[2;3H\e[31m\e7\e[5;5H\e[0m\e8x")
      assert Grid.cell(grid, 1, 2) == {?x, 0, Grid.indexed(1), 0}
    end

    test "CSI s and CSI u" do
      assert run("\e[3;4H\e[s\e[H\e[u") |> Grid.cursor() == {2, 3}
    end

    test "restore without save homes the cursor" do
      assert run("\e[3;4H\e8") |> Grid.cursor() == {0, 0}
    end
  end

  describe "scroll regions" do
    setup do
      %{lines: Enum.map_join(1..5, "\r\n", &"line#{&1}")}
    end

    test "LF at the region's bottom scrolls only the region", %{lines: lines} do
      assert text(lines <> "\e[2;4r\e[4;1H\nnew") == "line1\nline3\nline4\nnew\nline5"
    end

    test "RI at the region's top scrolls it down", %{lines: lines} do
      assert text(lines <> "\e[2;4r\e[2;1H\eMnew") == "line1\nnew\nline2\nline3\nline5"
    end

    test "SU and SD", %{lines: lines} do
      assert text(lines <> "\e[2;4r\e[S") == "line1\nline3\nline4\n\nline5"
      assert text(lines <> "\e[2;4r\e[2T") == "line1\n\n\nline2\nline5"
    end

    test "IL and DL inside the region", %{lines: lines} do
      assert text(lines <> "\e[1;4r\e[2;3H\e[L") == "line1\n\nline2\nline3\nline5"
      assert text(lines <> "\e[1;4r\e[2;3H\e[2M") == "line1\nline4\n\n\nline5"
    end

    test "IL outside the region does nothing", %{lines: lines} do
      assert text(lines <> "\e[1;3r\e[5;1H\e[L") == "line1\nline2\nline3\nline4\nline5"
    end

    test "DECSTBM homes the cursor; origin mode makes CUP relative" do
      assert run("\e[2;4r") |> Grid.cursor() == {0, 0}
      assert run("\e[2;4r\e[?6h") |> Grid.cursor() == {1, 0}
      assert run("\e[2;4r\e[?6h\e[9;1H") |> Grid.cursor() == {3, 0}
    end
  end

  describe "characters in a line" do
    test "ICH and DCH" do
      assert first_line("abcdefgh\e[3G\e[2@") == "ab  cdefgh"
      assert first_line("abcdefgh\e[3G\e[2P") == "abefgh"
    end

    test "insert mode shifts text right" do
      assert first_line("abcdef\e[2G\e[4hXY\e[4l") == "aXYbcdef"
    end

    test "REP repeats the last character" do
      assert first_line("ab\e[3b") == "abbbb"
    end

    test "autowrap off keeps writing on the last column" do
      assert first_line("\e[?7l0123456789XYZ") == "012345678Z"
    end
  end

  test "DECSCUSR sets the cursor shape; 0 gives it back to the user" do
    assert run("\e[5 q").cursor_style == {:bar, true}
    assert run("\e[4 q").cursor_style == {:underline, false}
    assert run("\e[2 q\e[0 q").cursor_style == nil
  end

  describe "line drawing" do
    test "ESC ( 0 maps to box drawing, ESC ( B goes back" do
      assert first_line("\e(0lqqk\e(B ok") == "┌──┐ ok"
    end

    test "SO and SI switch between G0 and G1" do
      assert first_line("\e)0x\x0Ex\x0Fx") == "x│x"
    end
  end

  describe "answers to queries" do
    test "device attributes" do
      assert responses("\e[c") == "\e[?62;22c"
      assert responses("\e[>c") == "\e[>1;10;0c"
    end

    test "status and cursor position" do
      assert responses("\e[5n") == "\e[0n"
      assert responses("\e[3;7H\e[6n") == "\e[3;7R"
      assert responses("\e[2;4r\e[?6h\e[2;2H\e[6n") == "\e[2;2R"
    end
  end

  describe "modes and title" do
    test "input modes" do
      grid = run("\e[?1h\e=\e[?2004h\e[?1002h\e[?1006h")

      assert grid.input == %{
               cursor_keys: :application,
               keypad: :application,
               bracketed_paste: true,
               mouse: 1002,
               mouse_sgr: true
             }

      assert run("\e[?1h\e[?1l\e>").input.cursor_keys == :normal
    end

    test "OSC 0 and 2 set the title, cleaned and capped" do
      assert run("\e]0;vim - file.ex\a").title == "vim - file.ex"
      assert run("\e]2;a\x01b\a").title == "ab"
      assert run("\e]2;" <> String.duplicate("x", 1000) <> "\a").title |> byte_size() == 256
    end

    test "DECSTR resets modes but keeps the screen" do
      grid = run("text\e[?7l\e[4h\e[2;3r\e[31m\e[!p")
      assert Grid.dump(grid) =~ "text"

      assert {grid.autowrap, grid.insert, grid.top, grid.bottom, grid.fg} ==
               {true, false, 0, 4, 0}
    end
  end

  test "resize in the alternate screen keeps the main one" do
    grid = run("main\e[?1049happ") |> Grid.resize(6, 3)
    assert run("\e[?1049l", 6, 3, grid) |> Grid.dump() == "main\n\n"
  end
end

defmodule Guiltty.ProgramsTest do
  @moduledoc """
  Real programs in a real session: "Done when" for v0.20.0 (book chapter 10,
  "Conformance"). A program that isn't installed is skipped, and says so.
  """
  use ExUnit.Case, async: true

  alias Guiltty.Session

  @moduletag timeout: 60_000

  setup context do
    id = context.test

    opts = [
      id: id,
      shell: System.find_executable("bash"),
      args: ["--norc", "--noprofile"],
      env: %{"PS1" => "$ ", "HISTFILE" => "/dev/null", "LC_ALL" => "C.UTF-8", "PAGER" => "less"},
      cols: 80,
      rows: 24
    ]

    start_supervised!({Session.Supervisor, opts})
    assert eventually(fn -> Session.dump(id) =~ ~r/^\$/m end)
    %{id: id}
  end

  defp eventually(fun, tries \\ 500) do
    if check(fun) or tries == 0,
      do: check(fun),
      else: Process.sleep(20) && eventually(fun, tries - 1)
  end

  defp check(fun) do
    fun.() == true
  catch
    :exit, _ -> false
  end

  defp run(id, line), do: Session.write(id, line <> "\r")

  defp shows(id, text),
    do: assert(eventually(fn -> Session.dump(id) =~ text end), Session.dump(id))

  # A program that exits throws away what was typed while it was closing
  # (TCSAFLUSH, tcsetattr(3)), so a line sent too soon is lost, in any terminal.
  # Keep asking until the shell answers.
  defp back_at_prompt(id, marker \\ "BACK") do
    answered =
      Enum.find_value(1..50, false, fn _ ->
        run(id, "echo #{marker}")
        if eventually(fn -> Session.dump(id) =~ ~r/^#{marker}$/m end, 25), do: true
      end)

    assert answered, Session.dump(id)
  end

  # A folder with a plain name: the test's own has quotes in it, and these
  # paths go through a shell.
  defp plain_dir do
    dir = Path.join(System.tmp_dir!(), "guiltty-programs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  setup context do
    needed = Enum.reject([context[:needs], context[:needs_too]], &is_nil/1)

    case Enum.reject(needed, &System.find_executable/1) do
      [] -> :ok
      [program | _] -> {:skip, "no #{program}"}
    end
  end

  @tag needs: "vim"
  test "vim: edit, resize while it runs, save; the shell's screen comes back", %{id: id} do
    path = Path.join(plain_dir(), "note.txt")
    run(id, "echo BEFORE")
    shows(id, ~r/^BEFORE$/m)
    run(id, "vim -u NONE -N #{path}")
    shows(id, "note.txt")
    Session.write(id, "ihello from guiltty\e")
    shows(id, "hello from guiltty")

    :ok = Session.resize(id, 100, 30)
    # vim redraws on the resize, and that wipes a message shown before it finishes.
    assert Enum.find_value(1..50, false, fn _ ->
             Session.write(id, ":\x15echo &columns\r")
             if eventually(fn -> Session.dump(id) =~ ~r/^100\s/m end, 25), do: true
           end),
           Session.dump(id)

    Session.write(id, ":wq\r")
    assert eventually(fn -> File.exists?(path) end)
    assert File.read!(path) == "hello from guiltty\n"
    back_at_prompt(id)
    assert Session.dump(id) =~ ~r/^BEFORE$/m
    refute Session.dump(id) =~ "hello from guiltty"
  end

  @tag needs: "less"
  test "less: pages, searches, quits back to the shell", %{id: id} do
    path = Path.join(plain_dir(), "lines.txt")
    File.write!(path, Enum.map_join(1..500, "\n", &"line #{&1}"))
    run(id, "less #{path}")
    shows(id, ~r/^line 1\s*$/m)
    Session.write(id, " ")
    shows(id, ~r/^line 24\s*$/m)
    Session.write(id, "/line 300\r")
    shows(id, "line 300")
    Session.write(id, "q")
    back_at_prompt(id)
    refute Session.dump(id) =~ "line 300"
  end

  @tag needs: "man"
  test "man: formats a page to the window's width", %{id: id} do
    run(id, "man 1 man")
    shows(id, ~r/MAN\(1\)/)
    Session.write(id, "q")
    back_at_prompt(id)
  end

  @tag needs: "top"
  test "top: full-screen redraws, then quits", %{id: id} do
    run(id, "top -d 0.2")
    shows(id, "load average")
    shows(id, "PID")
    Session.write(id, "q")
    back_at_prompt(id)
  end

  @tag needs: "nano"
  test "nano: types and saves", %{id: id} do
    path = Path.join(plain_dir(), "n.txt")
    run(id, "nano --ignorercfiles #{path}")
    shows(id, "n.txt")
    Session.write(id, "from nano")
    shows(id, "from nano")
    Session.write(id, <<0x18>> <> "y\r")
    assert eventually(fn -> File.exists?(path) end)
    assert File.read!(path) =~ "from nano"
    back_at_prompt(id)
  end

  @tag needs: "screen"
  test "screen: a terminal inside the terminal", %{id: id} do
    run(id, "SCREENDIR=#{plain_dir()} screen -q bash --norc --noprofile")
    # STY is only set inside screen: this can't pass in the outer shell.
    assert Enum.find_value(1..50, false, fn _ ->
             Session.write(id, "echo INSIDE-${STY:+yes}\r")
             if eventually(fn -> Session.dump(id) =~ ~r/^INSIDE-yes\s*$/m end, 25), do: true
           end),
           Session.dump(id)

    Session.write(id, "exit\r")
    back_at_prompt(id)
  end

  @tag needs: "tabs"
  test "tabs: custom tab stops are what they say", %{id: id} do
    run(id, "tabs -4; printf 'a\\tb\\n'")
    shows(id, ~r/^a   b$/m)
    run(id, "tabs -8; printf 'a\\tb\\n'")
    shows(id, ~r/^a       b$/m)
  end

  @tag needs: "tput"
  test "tput: what terminfo sends does what terminfo says", %{id: id} do
    run(id, "clear; tput cup 5 10; printf X; tput cup 7 0")
    shows(id, ~r/^ {10}X$/m)
    run(id, "tput smso; printf ' standout '; tput rmso; printf ' done\\n'")
    shows(id, "standout  done")
    run(id, "tput reset; echo AFTER-RESET")
    shows(id, ~r/^AFTER-RESET$/m)
  end

  test "the shell's lines rewrap when the window changes width", %{id: id} do
    long = String.duplicate("0123456789", 12)
    run(id, "clear; echo #{long}")
    shows(id, ~r/^#{String.slice(long, 80, 40)}$/m)
    :ok = Session.resize(id, 130, 24)
    shows(id, ~r/^#{long}$/m)
    :ok = Session.resize(id, 40, 24)
    shows(id, ~r/^#{String.slice(long, 0, 40)}$/m)
    back_at_prompt(id)
  end

  describe "tmux" do
    # tmux sees a VT520 and uses DECSLRM and DECFRA: a pane scrolling beside
    # another is drawn with left and right margins.
    defp tmux(id) do
      socket = "guiltty-test-#{System.unique_integer([:positive])}"
      on_exit(fn -> System.cmd("tmux", ["-L", socket, "kill-server"], stderr_to_stdout: true) end)
      run(id, "PS1='$ ' tmux -L #{socket} -f /dev/null new-session bash --norc --noprofile")
      assert eventually(fn -> Session.dump(id) =~ "[0]" end), Session.dump(id)
      assert eventually(fn -> Session.dump(id) =~ ~r/^\$/m end), Session.dump(id)
      # New panes too: not your shell and its config, which takes time to start.
      System.cmd("tmux", [
        "-L",
        socket,
        "set",
        "-g",
        "default-command",
        "PS1='$ ' bash --norc --noprofile"
      ])

      socket
    end

    # Column by column, what the left and right sides of the screen show.
    defp side(id, range) do
      Session.dump(id)
      |> String.split("\n")
      |> Enum.map(
        &(&1
          |> String.pad_trailing(80)
          |> String.slice(range)
          |> String.trim_trailing())
      )
    end

    @tag needs: "tmux"
    test "it uses margins and rectangles here", %{id: id} do
      socket = tmux(id)

      {features, 0} =
        System.cmd("tmux", ["-L", socket, "display", "-p", "\#{client_termfeatures}"])

      assert features =~ "margins"
      assert features =~ "rectfill"
    end

    @tag needs: "tmux"
    test "a pane scrolling beside another leaves it alone", %{id: id} do
      tmux(id)
      Session.write(id, "echo LEFT-A; echo LEFT-B\r")
      shows(id, ~r/^LEFT-B/m)
      # Ctrl+B %: a pane to the right, and the focus goes there.
      Session.write(id, <<2, ?%>>)
      assert eventually(fn -> Session.dump(id) =~ "│" end), Session.dump(id)
      Session.write(id, "seq 1 500; echo RIGHT-DONE\r")
      assert eventually(fn -> Session.dump(id) =~ "RIGHT-DONE" end), Session.dump(id)
      assert eventually(fn -> Session.dump(id) =~ ~r/│500\s*$/m end), Session.dump(id)

      left = side(id, 0..38)
      assert Enum.member?(left, "LEFT-A"), Session.dump(id)
      assert Enum.member?(left, "LEFT-B"), Session.dump(id)
      refute Enum.any?(left, &(&1 =~ ~r/^\d+$/)), Session.dump(id)

      # The border stays whole down the screen, and the numbers are in order.
      rows = Session.dump(id) |> String.split("\n") |> Enum.take(23)

      assert Enum.all?(rows, &(String.at(String.pad_trailing(&1, 80), 40) == "│")),
             Session.dump(id)

      numbers =
        side(id, 41..79)
        |> Enum.flat_map(fn line ->
          case Integer.parse(line) do
            {n, ""} -> [n]
            _ -> []
          end
        end)

      assert numbers == Enum.sort(numbers) and numbers != [], Session.dump(id)

      assert Enum.chunk_every(numbers, 2, 1, :discard) |> Enum.all?(fn [a, b] -> b == a + 1 end),
             Session.dump(id)
    end

    @tag needs: "tmux"
    test "a clear in one pane leaves the other", %{id: id} do
      tmux(id)
      Session.write(id, "echo STAYS\r")
      shows(id, ~r/^STAYS/m)
      Session.write(id, <<2, ?%>>)
      assert eventually(fn -> Session.dump(id) =~ "│" end)
      Session.write(id, "seq 1 15; clear; echo CLEARED\r")
      assert eventually(fn -> side(id, 41..79) |> Enum.member?("CLEARED") end), Session.dump(id)
      refute side(id, 41..79) |> Enum.any?(&(&1 =~ ~r/^\d+$/)), Session.dump(id)
      assert Enum.member?(side(id, 0..38), "STAYS"), Session.dump(id)
    end

    @tag needs: "tmux"
    test "panes survive the window changing size", %{id: id} do
      tmux(id)
      Session.write(id, "echo STAYS\r")
      shows(id, ~r/^STAYS/m)
      Session.write(id, <<2, ?%>>)
      assert eventually(fn -> Session.dump(id) =~ "│" end)
      :ok = Session.resize(id, 120, 30)
      assert eventually(fn -> Session.dump(id) |> String.split("\n") |> length() == 30 end)
      Session.write(id, "seq 1 200; echo DONE-1\r")
      assert eventually(fn -> Session.dump(id) =~ "DONE-1" end), Session.dump(id)
      assert eventually(fn -> Session.dump(id) =~ "STAYS" end), Session.dump(id)
      :ok = Session.resize(id, 70, 24)

      assert eventually(fn -> Session.dump(id) =~ "STAYS" and Session.dump(id) =~ "[0]" end),
             Session.dump(id)
    end
  end

  describe "tmux, as you'd use it" do
    defp grid(id), do: :sys.get_state(Session.via(id, :screen)).grid

    defp tmux_cmd(socket, args) do
      {out, 0} = System.cmd("tmux", ["-L", socket | args], stderr_to_stdout: true)
      out
    end

    defp split_right(id) do
      Session.write(id, <<2, ?%>>)
      assert eventually(fn -> Session.dump(id) =~ "│" end), Session.dump(id)
    end

    # What guiltty sends for the mouse in SGR mode (see Guiltty.Keymap.mouse/3).
    defp press(id, col, row, button \\ 0),
      do: Session.write(id, "\e[<#{button};#{col + 1};#{row + 1}M")

    defp drag(id, col, row), do: Session.write(id, "\e[<32;#{col + 1};#{row + 1}M")
    defp release(id, col, row), do: Session.write(id, "\e[<0;#{col + 1};#{row + 1}m")

    @tag needs: "tmux"
    test "true color reaches the cell", %{id: id} do
      tmux(id)
      Session.write(id, "clear; printf '\\033[38;2;255;100;0mORANGE\\033[0m\\n'\r")
      shows(id, ~r/^ORANGE/m)
      g = grid(id)

      row =
        Session.dump(id)
        |> String.split("\n")
        |> Enum.find_index(&String.starts_with?(&1, "ORANGE"))

      {?O, _attrs, fg, _bg} = Guiltty.Grid.cell(g, row, 0)
      assert fg == Guiltty.Grid.rgb(255, 100, 0)
    end

    @tag needs: "tmux"
    test "focus events reach the program in the pane", %{id: id} do
      socket = tmux(id)
      tmux_cmd(socket, ["set", "-g", "focus-events", "on"])
      # tmux only asks the terminal for focus events as a client attaches.
      Session.write(id, <<2, ?d>>)
      shows(id, "[detached")
      Session.write(id, "tmux -L #{socket} attach\r")
      assert eventually(fn -> grid(id).input.focus_events end), Session.dump(id)
      Session.write(id, "printf '\\033[?1004h'; cat -v\r")
      Process.sleep(300)
      # What the window sends when it loses and gains the keyboard.
      Session.write(id, "\e[O")
      Session.write(id, "\e[I")

      assert eventually(fn -> Session.dump(id) =~ "^[[O" and Session.dump(id) =~ "^[[I" end),
             Session.dump(id)
    end

    @tag needs: "tmux"
    test "copying in tmux reaches the clipboard, as OSC 52", %{id: id} do
      socket = tmux(id)
      tmux_cmd(socket, ["set", "-g", "set-clipboard", "on"])
      :ok = Session.Screen.subscribe(id, self())
      tmux_cmd(socket, ["set-buffer", "-w", "from tmux"])
      assert_receive {:clipboard, ^id, {:clipboard, "from tmux"}}, 5_000
    end

    @tag needs: "tmux"
    test "scrollback, in copy mode", %{id: id} do
      tmux(id)
      Session.write(id, "seq 1 2000; echo THE-END\r")
      shows(id, ~r/^THE-END/m)
      Session.write(id, <<2, ?[>>)
      Session.write(id, "\e[5~")
      assert eventually(fn -> Session.dump(id) =~ ~r/\[\d+\/\d+\]/ end), Session.dump(id)
      refute Session.dump(id) =~ "THE-END"
      assert Session.dump(id) =~ ~r/^19\d\d/m
      Session.write(id, "q")
      shows(id, ~r/^THE-END/m)
    end

    @tag needs: "tmux"
    test "detach and attach bring the screen back", %{id: id} do
      socket = tmux(id)
      Session.write(id, "echo STILL-HERE\r")
      shows(id, ~r/^STILL-HERE/m)
      Session.write(id, <<2, ?d>>)
      shows(id, "[detached")
      Session.write(id, "tmux -L #{socket} attach\r")
      shows(id, "[0]")
      shows(id, ~r/^STILL-HERE/m)
    end

    @tag needs: "vim"
    @tag needs_too: "tmux"
    test "vim in a pane: resized, then quit", %{id: id} do
      tmux(id)
      Session.write(id, "echo BEFORE-VIM\r")
      shows(id, ~r/^BEFORE-VIM/m)
      split_right(id)
      path = Path.join(plain_dir(), "pane.txt")
      Session.write(id, "vim -u NONE -N #{path}\r")
      # vim's own screen: the name alone could be the command being typed.
      assert eventually(fn -> Session.dump(id) =~ "│~" end), Session.dump(id)
      Session.write(id, "ifrom a pane\e")
      shows(id, "from a pane")
      :ok = Session.resize(id, 110, 30)

      assert eventually(fn ->
               Session.dump(id) =~ "from a pane" and Session.dump(id) =~ "BEFORE-VIM"
             end),
             Session.dump(id)

      Session.write(id, ":wq\r")
      assert eventually(fn -> File.exists?(path) end)
      assert File.read!(path) == "from a pane\n"

      assert eventually(fn ->
               Session.dump(id) =~ "BEFORE-VIM" and not (Session.dump(id) =~ "from a pane")
             end),
             Session.dump(id)
    end

    @tag needs: "tmux"
    test "the mouse: asks for it, clicks a pane, drags a border, scrolls", %{id: id} do
      socket = tmux(id)
      tmux_cmd(socket, ["set", "-g", "mouse", "on"])
      assert eventually(fn -> grid(id).input.mouse != nil and grid(id).input.mouse_sgr end)
      split_right(id)
      index = fn -> tmux_cmd(socket, ["display", "-p", "\#{pane_index}"]) |> String.trim() end
      assert index.() == "1"

      # A click in the left pane focuses it.
      press(id, 5, 5)
      release(id, 5, 5)
      assert eventually(fn -> index.() == "0" end)

      # A drag on the border moves it.
      width = fn -> tmux_cmd(socket, ["display", "-p", "\#{pane_width}"]) |> String.trim() end
      assert width.() == "40"
      press(id, 40, 5)
      drag(id, 30, 5)
      release(id, 30, 5)
      assert eventually(fn -> width.() != "40" end), Session.dump(id)
      assert String.to_integer(width.()) < 40

      # The wheel over a pane scrolls it back, in copy mode.
      Session.write(id, "seq 1 500\r")
      assert eventually(fn -> Session.dump(id) =~ ~r/^500/m end), Session.dump(id)
      press(id, 5, 5, 64)
      assert eventually(fn -> Session.dump(id) =~ ~r/\[\d+\/\d+\]/ end), Session.dump(id)
    end
  end

  @tag needs: "htop"
  test "htop: draws its meters and quits", %{id: id} do
    run(id, "htop")
    shows(id, "Load average")
    shows(id, "PID")
    Session.write(id, "q")
    back_at_prompt(id)
  end

  @tag needs: "mc"
  test "mc: draws its panels, line drawing and all, and quits", %{id: id} do
    run(id, "HOME=#{plain_dir()} mc --nosubshell")
    shows(id, "Name")
    shows(id, ~r/[┌│]/)
    # F10, and yes.
    Session.write(id, "\e[21~")
    Process.sleep(500)
    Session.write(id, "y\r")
    back_at_prompt(id)
  end

  describe "a shell's prompt when the window changes width" do
    # A prompt like powerlevel10k's: a top row filled to the right edge, and a
    # row to type on. On SIGWINCH the shell moves up as many rows as it knows
    # the prompt took, erases down, and draws it again.
    defp zsh_session(id) do
      dir = plain_dir()

      File.write!(Path.join(dir, ".zshrc"), ~S"""
      setopt promptsubst
      # A moment's work per prompt, as powerlevel10k's has: resizes overtake it.
      PROMPT='TOP${(l:$((COLUMNS-6))::.:)}END$(sleep 0.03)'$'\n''> '
      """)

      opts = [
        id: {id, :zsh},
        shell: System.find_executable("zsh"),
        args: [],
        env: %{"ZDOTDIR" => dir, "HISTFILE" => "/dev/null"},
        cols: 80,
        rows: 24
      ]

      start_supervised!(%{id: :zsh, start: {Session.Supervisor, :start_link, [opts]}})
      {id, :zsh}
    end

    defp prompts(id) do
      grid = :sys.get_state(Session.via(id, :screen)).grid

      for n <- grid.scrollback_first..(grid.history + grid.rows - 1),
          line = Guiltty.Grid.line(grid, n),
          Guiltty.Grid.line_text(grid, line) =~ "TOP",
          do: n
    end

    # What's settled: the same screen twice, a moment apart.
    defp settle(id) do
      first = Session.dump(id)
      Process.sleep(150)
      if Session.dump(id) != first, do: settle(id)
    end

    @tag needs: "zsh"
    test "zsh with a full-width prompt leaves no copies behind", %{id: id} do
      zsh = zsh_session(id)
      assert eventually(fn -> Session.dump(zsh) =~ "END" end), Session.dump(zsh)

      for cols <- [70, 60, 50, 40, 60, 80, 45, 100, 33, 80] do
        :ok = Session.resize(zsh, cols, 24)
        settle(zsh)
      end

      assert length(prompts(zsh)) == 1, Session.dump(zsh)
      assert Session.dump(zsh) =~ ~r/^>\s*$/m
    end

    # A window being dragged: dozens of sizes a second, far faster than zsh can
    # redraw, narrowing and widening.
    @tag needs: "zsh"
    test "dragging the window's edge leaves no copies, and keeps the output", %{id: id} do
      zsh = zsh_session(id)
      assert eventually(fn -> Session.dump(zsh) =~ "END" end), Session.dump(zsh)
      Session.write(zsh, "print -l FIRST SECOND THIRD\r")
      shows(zsh, ~r/^THIRD$/m)
      settle(zsh)

      for cols <- Enum.concat([80..30//-3, 30..110//4, 110..50//-5, 50..90//2]) do
        :ok = Session.resize(zsh, cols, 24)
        Process.sleep(2)
      end

      settle(zsh)
      Process.sleep(300)
      settle(zsh)
      # The prompt before the command, and the one now.
      assert length(prompts(zsh)) == 2, Session.dump(zsh)
      for word <- ~w(FIRST SECOND THIRD), do: assert(Session.dump(zsh) =~ ~r/^#{word}$/m)
    end

    @tag needs: "zsh"
    test "what came before the prompt still rewraps", %{id: id} do
      zsh = zsh_session(id)
      assert eventually(fn -> Session.dump(zsh) =~ "END" end)
      long = String.duplicate("0123456789", 12)
      Session.write(zsh, "print #{long}\r")
      shows(zsh, ~r/^#{String.slice(long, 80, 40)}$/m)
      settle(zsh)
      :ok = Session.resize(zsh, 130, 24)
      shows(zsh, ~r/^#{long}$/m)
      settle(zsh)
      :ok = Session.resize(zsh, 40, 24)
      shows(zsh, ~r/^#{String.slice(long, 0, 40)}$/m)
      settle(zsh)
      assert length(prompts(zsh)) == 2, Session.dump(zsh)
    end

    @tag needs: "zsh"
    test "what's typed on the prompt comes back", %{id: id} do
      zsh = zsh_session(id)
      assert eventually(fn -> Session.dump(zsh) =~ "END" end)
      Session.write(zsh, "print half-typed")
      shows(zsh, "half-typed")
      :ok = Session.resize(zsh, 40, 24)
      settle(zsh)
      shows(zsh, ~r/^> print half-typed/m)
      Session.write(zsh, "\r")
      shows(zsh, ~r/^half-typed$/m)
    end
  end

  test "a flood through a wrapping window keeps every line", %{id: id} do
    run(id, "seq 1 20000; echo FLOOD-OVER")
    assert eventually(fn -> Session.dump(id) =~ ~r/^FLOOD-OVER$/m end), Session.dump(id)
    :ok = Session.resize(id, 3, 24)
    :ok = Session.resize(id, 80, 24)
    back_at_prompt(id)
  end
end

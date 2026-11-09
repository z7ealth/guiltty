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
    case context[:needs] do
      nil -> :ok
      program -> if System.find_executable(program), do: :ok, else: {:skip, "no #{program}"}
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
    Session.write(id, ":\x15echo &columns\r")
    shows(id, ~r/^100\s/m)

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

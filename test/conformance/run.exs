# Runs an outside conformance suite and records what it says, as a baseline to
# compare later runs against. Book chapter 10, "Conformance".
#
#   mix run --no-start test/conformance/run.exs esctest [--include=REGEX]
#   mix run --no-start test/conformance/run.exs esctest-xterm [--include=REGEX]
#   mix run --no-start test/conformance/run.exs ucs-detect
#
# ESCTEST_DIR is esctest2's esctest/ folder; UCS_DETECT is the program's path.
#
# guiltty's runs happen in a real session (Pty, Screen, Parser) with no window:
# the suite talks to the same code a window would show, and its questions are
# answered the same way. esctest-xterm runs in a real xterm on a private
# display, because xterm is what esctest measures everyone against.

defmodule Conformance do
  alias Guiltty.Session

  @baselines "test/conformance/baselines"
  @cols 80
  # esctest needs at least 25 rows.
  @rows 25
  @time_limit :timer.minutes(30)
  @display ":77"

  def main(["esctest" | rest]) do
    log = temp_log()
    run_in_session(System.find_executable("python3"), esctest_args(log, rest), esctest_dir())
    record("esctest-guiltty", log, rest)
  end

  def main(["esctest-xterm" | rest]) do
    log = temp_log()
    run_in_xterm(xterm_args(log, rest))
    record("esctest-xterm", log, rest)
  end

  def main(["ucs-detect" | _]) do
    program = System.fetch_env!("UCS_DETECT")
    File.mkdir_p!(@baselines)
    yaml = Path.expand(Path.join(@baselines, "ucs-detect-guiltty.yaml"))
    args = ["--save-yaml=#{yaml}", "--no-final-summary", "--set-software-name=guiltty"]
    run_in_session(program, args, File.cwd!())
    IO.puts("saved #{Path.relative_to_cwd(yaml)}")
  end

  def main(_), do: IO.puts("usage: run.exs esctest | esctest-xterm | ucs-detect")

  defp esctest_dir, do: System.fetch_env!("ESCTEST_DIR")

  defp temp_log,
    do: Path.join(System.tmp_dir!(), "esctest-#{System.unique_integer([:positive])}.log")

  # A short timeout: on a machine this fast an answer takes far less, and a
  # sequence with no answer would otherwise cost a full second per test.
  defp esctest_args(log, rest) do
    [
      Path.join(esctest_dir(), "esctest.py"),
      "--expected-terminal=xterm",
      "--logfile=#{log}",
      "--no-print-logs",
      "--timeout=0.2",
      # Erased cells are spaces here, as on a DEC terminal: this tells esctest
      # to expect that, and DEC's checksum (the one DECRQCRA gives).
      "--xterm-checksum=278",
      # guiltty's reverse wrap is xterm's since patch 383: only over rows that wrapped.
      "--xterm-reverse-wrap=383"
    ] ++ rest
  end

  # Everything set the way esctest's README says to test xterm itself: its own
  # patch's checksum and reverse wrap, and the window operations it lets on.
  defp xterm_args(log, rest) do
    {version, 0} = System.cmd("xterm", ["-version"])
    patch = version |> String.trim() |> String.replace(~r/\D/, "")

    [
      Path.join(esctest_dir(), "esctest.py"),
      "--expected-terminal=xterm",
      "--logfile=#{log}",
      "--no-print-logs",
      "--timeout=1",
      "--xterm-checksum=#{patch}",
      "--xterm-reverse-wrap=#{patch}",
      "--options",
      "xtermWinopsEnabled"
    ] ++ rest
  end

  defp run_in_session(program, args, dir) do
    {:ok, _} = Registry.start_link(keys: :unique, name: Guiltty.Registry)

    {:ok, sup} =
      Session.Supervisor.start_link(
        id: :conformance,
        shell: program,
        args: args,
        cwd: dir,
        cols: @cols,
        rows: @rows,
        scrollback: 1_000,
        # esctest reads the screen through DECRQCRA, which is off by default.
        screen_reports: true
      )

    Process.unlink(sup)
    ref = Process.monitor(sup)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    after
      @time_limit ->
        IO.puts("gave up after #{div(@time_limit, 60_000)} minutes; the screen:")
        IO.puts(Session.dump(:conformance))
    end
  end

  # The resources esctest's README gives: VT level 5, and window operations on.
  defp run_in_xterm(args) do
    xvfb_path =
      System.find_executable("Xvfb") ||
        raise "esctest-xterm needs Xvfb, a private display (xorg-x11-server-Xvfb on openSUSE)"

    xvfb =
      Port.open({:spawn_executable, xvfb_path}, args: [@display, "-screen", "0", "1280x1024x24"])

    Process.sleep(500)

    resources = [
      "XTerm*decTerminalID: 520",
      "XTerm*utf8: 1",
      "XTerm*wideChars: true",
      "XTerm*allowWindowOps: true",
      "XTerm*disallowedWindowOps:"
    ]

    xrm = Enum.flat_map(resources, &["-xrm", &1])

    command =
      ["-geometry", "#{@cols}x#{@rows}" | xrm] ++ ["-e", System.find_executable("python3") | args]

    System.cmd("xterm", command,
      env: [{"DISPLAY", @display}],
      cd: esctest_dir(),
      stderr_to_stdout: true
    )

    case Port.info(xvfb, :os_pid) do
      {:os_pid, pid} -> System.cmd("kill", [to_string(pid)])
      nil -> :ok
    end
  end

  # The last lines of esctest's log are the totals and the failures. A run
  # limited with --include is printed, not saved: it isn't a baseline.
  defp record(name, log, rest) do
    summary = summary(File.read!(log))
    File.rm(log)
    IO.puts(summary)

    if rest == [] do
      File.mkdir_p!(@baselines)
      path = Path.join(@baselines, name <> ".txt")
      File.write!(path, summary)
      IO.puts("saved #{path}")
    end
  end

  defp summary(log) do
    lines = String.split(log, "\n")

    # Not just any "*** " line: each failed test prints "*** TEST x FAILED:".
    case Enum.find_index(lines, &(&1 =~ ~r/^\*\*\* \d+ tests? passed/)) do
      nil ->
        "esctest stopped before printing its totals. The end of its log:\n" <>
          (lines |> Enum.take(-20) |> Enum.join("\n"))

      i ->
        [totals | rest] = Enum.drop(lines, i)
        failing = rest |> Enum.drop_while(&(&1 != "Failing tests:")) |> Enum.drop(1)
        names = failing |> Enum.reject(&(&1 == "")) |> Enum.sort()
        Enum.join([totals, "" | names], "\n") <> "\n"
    end
  end
end

Conformance.main(System.argv())

defmodule Guiltty.LauncherTest do
  # The `guiltty` command (the C client, priv/guiltty) and the socket it
  # talks to (Guiltty.Launcher). Desks, Sessions and Lifeline have global
  # names: not async.
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Guiltty.{Desk, Launcher, Lifeline}

  @env [
    {~c"SDL_VIDEO_DRIVER", ~c"offscreen"},
    {~c"ASAN_OPTIONS", ~c"detect_leaks=0"},
    {~c"UBSAN_OPTIONS", ~c"halt_on_error=1:print_stacktrace=1"}
  ]
  @client Path.join(:code.priv_dir(:guiltty), "guiltty")

  # A Unix socket path must fit in 108 bytes: the test's tmp_dir doesn't.
  defp short_dir do
    dir = Path.join(System.tmp_dir!(), "gl-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp start_guiltty(path) do
    start_supervised!({DynamicSupervisor, name: Guiltty.Sessions, strategy: :one_for_one})
    start_supervised!({DynamicSupervisor, name: Guiltty.Desks, strategy: :one_for_one})
    start_supervised!(Supervisor.child_spec(Lifeline, restart: :temporary))
    start_supervised!({Launcher, path: path, window: [env: @env]})
  end

  # (Not named check/1: ExUnitProperties has a check macro.)
  defp eventually(fun, tries \\ 250) do
    if holds?(fun) or tries == 0,
      do: holds?(fun),
      else: Process.sleep(20) && eventually(fun, tries - 1)
  end

  defp holds?(fun) do
    fun.()
  catch
    :exit, _ -> false
  end

  # The client, with this environment; {output, exit status}.
  defp client(args, env) do
    System.cmd(@client, args, env: env, stderr_to_stdout: true)
  end

  # Talks to the socket directly, the way a broken or hostile client would.
  defp raw(path, bytes) do
    {:ok, s} = :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :line])
    :ok = :gen_tcp.send(s, bytes)
    reply = :gen_tcp.recv(s, 0, 5_000)
    :gen_tcp.close(s)
    reply
  end

  describe "parse_request/1" do
    test "takes the display variables and the folder, and nothing else" do
      assert {:ok,
              %{
                env: [{~c"DISPLAY", ~c":0"}, {~c"XAUTHORITY", ~c"/home/me/.Xauthority"}],
                cwd: nil
              }} =
               Launcher.parse_request([
                 "guiltty 1 open\n",
                 "DISPLAY=:0\n",
                 "XAUTHORITY=/home/me/.Xauthority\n"
               ])

      assert {:ok, %{env: [], cwd: "/home/me/src"}} =
               Launcher.parse_request(["guiltty 1 open\n", "PWD=/home/me/src\n"])

      # A folder must be an absolute path.
      assert {:error, _} = Launcher.parse_request(["guiltty 1 open\n", "PWD=src\n"])

      assert {:error, _} = Launcher.parse_request(["guiltty 1 open\n", "LD_PRELOAD=/evil.so\n"])
      assert {:error, _} = Launcher.parse_request(["guiltty 1 open\n", "DISPLAY=:0\e[2J\n"])

      assert {:error, "this guiltty speaks version 1" <> _} =
               Launcher.parse_request(["guiltty 2 open\n"])

      assert {:error, _} = Launcher.parse_request(["guiltty 1 run rm -rf ~\n"])
      assert {:error, _} = Launcher.parse_request([])
    end

    property "never raises, whatever it's given" do
      check all(
              lines <-
                StreamData.list_of(
                  StreamData.one_of([
                    StreamData.binary(max_length: 200),
                    StreamData.constant("guiltty 1 open\n"),
                    StreamData.map(StreamData.binary(max_length: 200), &("DISPLAY=" <> &1)),
                    # anything at all, kept small: big nested terms are
                    # slow to make, and no bigger a test
                    StreamData.resize(StreamData.term(), 5)
                  ]),
                  max_length: 20
                ),
              max_runs: 1_000
            ) do
        assert match?({:ok, _}, Launcher.parse_request(lines)) or
                 match?({:error, _}, Launcher.parse_request(lines))
      end
    end
  end

  describe "the socket" do
    test "the client asks, and a window opens" do
      path = Path.join(short_dir(), "sock")
      start_guiltty(path)

      assert {"", 0} = client([], [{"GUILTTY_SOCKET", path}, {"DISPLAY", ":99"}])
      assert [desk] = Desk.all()
      assert desk |> Desk.tabs() |> Guiltty.Tabs.list() |> elem(0) |> length() == 1
    end

    test "the new window's first tab starts in the folder the client ran in" do
      dir = short_dir()
      path = Path.join(dir, "sock")
      start_guiltty(path)
      here = Path.join(dir, "here")
      File.mkdir_p!(here)

      {_, 0} = System.cmd(@client, [], cd: here, env: [{"GUILTTY_SOCKET", path}])
      [desk] = Desk.all()
      id = Guiltty.Tabs.active(Desk.tabs(desk))
      # Its shell reports where it is (the Pty reads /proc/<pid>/cwd).
      assert eventually(fn -> Guiltty.Session.Pty.cwd(id) == here end)
    end

    test "broken requests get an error, never a window" do
      path = Path.join(short_dir(), "sock")
      start_guiltty(path)

      assert {:ok, "error: not a guiltty request\n"} = raw(path, "hello\n\n")
      assert {:ok, "error: unexpected line" <> _} = raw(path, "guiltty 1 open\nPATH=/x\n\n")
      assert {:ok, "error: this guiltty speaks" <> _} = raw(path, "guiltty 9 open\n\n")
      # Over the line limit the socket closes before the answer can go:
      # refused either way.
      assert raw(path, String.duplicate("x", 5_000) <> "\n") in [
               {:ok, "error: line too long\n"},
               {:error, :closed}
             ]

      assert {:ok, "error: request too long\n"} =
               raw(path, "guiltty 1 open\n" <> String.duplicate("DISPLAY=:0\n", 20) <> "\n")

      assert Desk.all() == []
    end

    test "a client that says nothing is dropped, and doesn't hold up the next" do
      path = Path.join(short_dir(), "sock")
      start_guiltty(path)

      {:ok, silent} = :gen_tcp.connect({:local, path}, 0, [:binary, active: false])
      assert {"", 0} = client([], [{"GUILTTY_SOCKET", path}])
      assert {:ok, "error: request incomplete\n"} = :gen_tcp.recv(silent, 0, 5_000)
    end

    test "while guiltty shuts down, the answer says so" do
      path = Path.join(short_dir(), "sock")
      start_supervised!({Launcher, path: path})
      # No Lifeline: what the Launcher sees in the moment after the last
      # window closed.
      assert {:ok, "error: shutting down\n"} = raw(path, "guiltty 1 open\n\n")
    end

    test "the socket's folder is made private" do
      dir = short_dir()
      File.chmod!(dir, 0o755)
      start_supervised!({Launcher, path: Path.join(dir, "sock")})
      assert File.stat!(dir).mode |> Bitwise.band(0o777) == 0o700
    end
  end

  describe "the client on its own" do
    # A stand-in for the release's script: it writes down its arguments.
    defp fake_release(dir) do
      script = Path.join(dir, "fake-release")
      File.write!(script, "#!/bin/sh\necho \"$@\" > #{dir}/ran\n")
      File.chmod!(script, 0o755)
      script
    end

    test "nobody listening: it starts guiltty (the release's daemon)" do
      dir = short_dir()
      env = [{"GUILTTY_SOCKET", Path.join(dir, "sock")}, {"GUILTTY_RELEASE", fake_release(dir)}]
      assert {_, 0} = client([], env)
      assert File.read!(Path.join(dir, "ran")) == "daemon\n"
    end

    test "a socket left by a guiltty that's gone counts as nobody" do
      dir = short_dir()
      path = Path.join(dir, "sock")
      # Listen, then close without removing the file: a crashed guiltty's.
      {:ok, l} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}])
      :gen_tcp.close(l)
      assert File.exists?(path)

      assert {_, 0} =
               client([], [{"GUILTTY_SOCKET", path}, {"GUILTTY_RELEASE", fake_release(dir)}])

      assert File.read!(Path.join(dir, "ran")) == "daemon\n"
    end

    test "arguments go to the release's script, as before" do
      dir = short_dir()
      env = [{"GUILTTY_SOCKET", Path.join(dir, "sock")}, {"GUILTTY_RELEASE", fake_release(dir)}]
      assert {_, 0} = client(["stop"], env)
      assert File.read!(Path.join(dir, "ran")) == "stop\n"
    end
  end
end

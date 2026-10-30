defmodule Guiltty.WindowTest do
  # Runs the real renderer (the AddressSanitizer + UBSan build) on SDL's
  # offscreen driver, so no window appears.
  use ExUnit.Case, async: true

  alias Guiltty.{Session, Window}

  # Leak checking is off here only: Mesa's offscreen EGL driver leaks a few
  # bytes from a library it unloads before exit. Run the renderer on X11 or
  # Wayland to check leaks.
  @env [
    {~c"SDL_VIDEO_DRIVER", ~c"offscreen"},
    {~c"ASAN_OPTIONS", ~c"detect_leaks=0"},
    {~c"UBSAN_OPTIONS", ~c"halt_on_error=1:print_stacktrace=1"}
  ]

  setup context do
    id = context.test

    opts = [
      id: id,
      shell: System.find_executable("bash"),
      args: ["--norc", "--noprofile"],
      env: %{"PS1" => "$ "}
    ]

    start_supervised!({Session.Supervisor, opts})
    window_spec = {Window, session: id, name: false, env: @env}
    window = start_supervised!(Supervisor.child_spec(window_spec, restart: :temporary))
    assert eventually(fn -> :sys.get_state(window).ready end), "no handshake"
    %{id: id, window: window}
  end

  defp eventually(fun, tries \\ 250) do
    if fun.() or tries == 0, do: fun.(), else: Process.sleep(20) && eventually(fun, tries - 1)
  end

  defp port(window), do: :sys.get_state(window).port

  test "handshakes and keeps the renderer fed", %{id: id, window: window} do
    Session.write(id, "seq 1 40\r")
    assert eventually(fn -> Session.dump(id) =~ ~r/^40$/m end)
    # Give the renderer time to apply the rows; a bad message would make it exit.
    Process.sleep(200)
    assert Process.alive?(window)
    assert Port.info(port(window))
  end

  test "key events from the renderer reach the shell", %{id: id, window: window} do
    assert eventually(fn -> Session.dump(id) =~ ~r/^\$/m end)
    port = port(window)
    # Pretend the renderer sent these: text, then Enter.
    for msg <- [<<4, "echo key-path">>, <<5, 0x0D::32, 0::16>>] do
      send(window, {port, {:data, msg}})
    end

    assert eventually(fn -> Session.dump(id) =~ ~r/^key-path$/m end)
  end

  test "the window follows a restarted screen", %{id: id, window: window} do
    for role <- [:screen, :supervisor] do
      old = GenServer.whereis(Session.via(id, :screen))
      Process.exit(GenServer.whereis(Session.via(id, role)), :kill)

      assert eventually(fn ->
               screen = GenServer.whereis(Session.via(id, :screen))
               screen not in [nil, old] and window in :sys.get_state(screen).subscribers
             end),
             "window not subscribed after killing #{role}"
    end

    assert Process.alive?(window)
  end

  test "a resize from the renderer reaches the grid and the shell", %{id: id, window: window} do
    assert eventually(fn -> Session.dump(id) =~ ~r/^\$/m end)
    # What the renderer sends when the user makes the window 100x30.
    send(window, {port(window), {:data, <<6, 100::16, 30::16>>}})
    assert eventually(fn -> length(String.split(Session.dump(id), "\n")) == 30 end)
    Session.write(id, "stty size\r")
    assert eventually(fn -> Session.dump(id) =~ ~r/^30 100$/m end)
  end

  test "the program's queries are answered through the PTY", %{id: id} do
    # bash asks the terminal for the cursor position; the answer comes back
    # as if typed, and `read` picks it up.
    Session.write(id, "printf '\\e[6n'; IFS= read -rsd R pos; echo got${pos#*[}\r")
    assert eventually(fn -> Session.dump(id) =~ ~r/^got\d+;\d+$/m end)
  end

  test "paste and mouse events reach the shell as bytes", %{id: id, window: window} do
    assert eventually(fn -> Session.dump(id) =~ ~r/^\$/m end)
    port = port(window)
    send(window, {port, {:data, <<8, "echo pasted\n">>}})
    assert eventually(fn -> Session.dump(id) =~ ~r/^pasted$/m end)

    # With mouse mode on, a click arrives in the shell as an SGR report;
    # `cat -v` shows it.
    Session.write(id, "printf '\\e[?1000h\\e[?1006h'; cat -v\r")
    # Wait until the Window knows mouse mode is on; a click before that is
    # (correctly) not reported.
    assert eventually(fn -> match?(%{mouse: 1000}, :sys.get_state(window).input) end)
    send(window, {port, {:data, <<9, 0, 0, 4::16, 2::16, 0::16>>}})
    Session.write(id, "\r\x04")
    assert eventually(fn -> Session.dump(id) =~ "^[[<0;5;3M" end)
  end

  test "stopping the window ends the renderer process", %{window: window} do
    {:os_pid, os_pid} = Port.info(port(window), :os_pid)
    assert File.exists?("/proc/#{os_pid}")
    GenServer.stop(window)
    assert eventually(fn -> not File.exists?("/proc/#{os_pid}") end)
  end

  test "the renderer rejects a malformed message without crashing", %{window: window} do
    port = port(window)
    ref = Process.monitor(window)
    # A rows message for the right grid size, claiming 5 rows but carrying
    # half of one.
    Port.command(port, <<3, 80::16, 24::16, 0::16, 0::16, 1, 5::16, 0::16, 0::size(400)-unit(8)>>)
    # The renderer exits with status 2 (protocol error), not a sanitizer crash.
    assert_receive {:DOWN, ^ref, :process, ^window, {:renderer_exited, 2}}, 5000
  end
end

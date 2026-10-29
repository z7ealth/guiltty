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
    opts = [id: id, args: ["--norc", "--noprofile"], env: %{"PS1" => "$ "}]
    start_supervised!({Session.Supervisor, opts})
    window_spec = {Window, session: id, name: false, env: @env}
    window = start_supervised!(Supervisor.child_spec(window_spec, restart: :temporary))
    assert eventually(fn -> :sys.get_state(window).ready end), "no handshake"
    %{id: id, window: window}
  end

  defp eventually(fun, tries \\ 150) do
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

  test "stopping the window ends the renderer process", %{window: window} do
    {:os_pid, os_pid} = Port.info(port(window), :os_pid)
    assert File.exists?("/proc/#{os_pid}")
    GenServer.stop(window)
    assert eventually(fn -> not File.exists?("/proc/#{os_pid}") end)
  end

  test "the renderer rejects a malformed message without crashing", %{window: window} do
    port = port(window)
    ref = Process.monitor(window)
    # A rows message claiming more rows than it carries.
    Port.command(port, <<3, 0::16, 0::16, 5::16, 0::16, 3::16, "ab">>)
    # The renderer exits with status 2 (protocol error), not a sanitizer crash.
    assert_receive {:DOWN, ^ref, :process, ^window, {:renderer_exited, 2}}, 3000
  end
end

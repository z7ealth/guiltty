defmodule Guiltty.WindowTest do
  # Runs the real renderer (the AddressSanitizer + UBSan build) on SDL's
  # offscreen driver, so no window appears. Guiltty.Tabs has a global name,
  # so these tests run one at a time.
  use ExUnit.Case, async: false

  alias Guiltty.{Config, Grid, Session, Tabs, Window}
  alias Guiltty.Session.Screen

  # Leak checking is off here only: Mesa's offscreen EGL driver leaks a few
  # bytes from a library it unloads before exit. Run the renderer on X11 or
  # Wayland to check leaks.
  @env [
    {~c"SDL_VIDEO_DRIVER", ~c"offscreen"},
    {~c"ASAN_OPTIONS", ~c"detect_leaks=0"},
    {~c"UBSAN_OPTIONS", ~c"halt_on_error=1:print_stacktrace=1"}
  ]

  @ctrl 0x0040
  @shift 0x0001

  setup do
    start_supervised!({DynamicSupervisor, name: Guiltty.Sessions, strategy: :one_for_one})

    session_opts = [
      shell: System.find_executable("bash"),
      args: ["--norc", "--noprofile"],
      env: %{"PS1" => "$ "}
    ]

    start_supervised!({Tabs, session_opts: session_opts})
    window = start_window()
    id = Tabs.active()
    assert eventually(fn -> Session.dump(id) =~ ~r/^\$/m end)
    %{id: id, window: window}
  end

  defp start_window do
    spec =
      Supervisor.child_spec({Window, name: false, env: @env}, restart: :temporary, id: make_ref())

    window = start_supervised!(spec)
    assert eventually(fn -> :sys.get_state(window).ready end), "no handshake"
    window
  end

  # Retries for up to 5 seconds. A process that's restarting may not be
  # registered yet; that counts as "not yet", not as a failure.
  defp eventually(fun, tries \\ 250) do
    if check(fun) or tries == 0,
      do: check(fun),
      else: Process.sleep(20) && eventually(fun, tries - 1)
  end

  defp check(fun) do
    fun.()
  catch
    :exit, _ -> false
  end

  defp port(window), do: :sys.get_state(window).port
  defp renderer(window, msg), do: send(window, {port(window), {:data, msg}})
  defp key(window, code, mods), do: renderer(window, <<5, code::32, mods::16>>)

  test "handshakes, and the renderer reports every frame", %{id: id, window: window} do
    Session.write(id, "seq 1 40\r")
    assert eventually(fn -> Session.dump(id) =~ ~r/^40$/m end)
    # Each update waits for the renderer's frame report; the last one came.
    assert eventually(fn -> not :sys.get_state(window).awaiting_frame end)
    assert Port.info(port(window))
  end

  test "key events reach the active tab's shell", %{id: id, window: window} do
    renderer(window, <<4, "echo key-path">>)
    key(window, 0x0D, 0)
    assert eventually(fn -> Session.dump(id) =~ ~r/^key-path$/m end)
  end

  test "Ctrl+Shift+T opens a tab, Ctrl+Shift+W closes it, the window follows", %{
    id: first,
    window: window
  } do
    key(window, ?t, @ctrl ||| @shift)
    assert eventually(fn -> match?({[_, _], _}, Tabs.list()) end)
    {_tabs, second} = Tabs.list()
    assert second != first
    assert eventually(fn -> :sys.get_state(window).active == second end)

    # Typing goes to the new tab now.
    renderer(window, <<4, "echo in-second">>)
    key(window, 0x0D, 0)
    assert eventually(fn -> Session.dump(second) =~ ~r/^in-second$/m end)
    refute Session.dump(first) =~ "in-second"

    key(window, ?w, @ctrl ||| @shift)
    assert eventually(fn -> Tabs.list() == {[{first, Screen.title(first)}], first} end)
    assert eventually(fn -> :sys.get_state(window).active == first end)
  end

  test "Ctrl+PgDn and a click on the tab bar switch tabs", %{id: first, window: window} do
    {:ok, second} = Tabs.new_tab()
    key(window, 0x4000004E, @ctrl)
    assert eventually(fn -> Tabs.active() == first end)
    renderer(window, <<16, 1>>)
    assert eventually(fn -> Tabs.active() == second end)
  end

  test "closing the window leaves the tabs running; a new window shows them", %{
    id: id,
    window: window
  } do
    Session.write(id, "echo still-here\r")
    {:ok, second} = Tabs.new_tab()
    {:os_pid, os_pid} = Port.info(port(window), :os_pid)

    GenServer.stop(window)
    assert eventually(fn -> not File.exists?("/proc/#{os_pid}") end)
    assert Tabs.list() |> elem(0) |> length() == 2
    assert Session.dump(id) =~ ~r/^still-here$/m

    window = start_window()
    assert :sys.get_state(window).active == second
    assert Enum.map(:sys.get_state(window).tabs, &elem(&1, 0)) == [id, second]
  end

  test "a killed parser comes back; the screen and the shell survive", %{
    id: id,
    window: window
  } do
    Session.write(id, "echo before-kill\r")
    assert eventually(fn -> Session.dump(id) =~ ~r/^before-kill$/m end)
    parser = GenServer.whereis(Session.via(id, :parser))

    Process.exit(parser, :kill)
    assert eventually(fn -> GenServer.whereis(Session.via(id, :parser)) not in [nil, parser] end)

    assert Session.dump(id) =~ ~r/^before-kill$/m
    Session.write(id, "echo after-kill\r")
    assert eventually(fn -> Session.dump(id) =~ ~r/^after-kill$/m end)
    assert Process.alive?(window)
  end

  test "a new theme and a new font apply to the open window", %{window: window} do
    config = Config.defaults()
    theme = %{config.theme | bg: {0, 0, 64}}
    send(window, {:config, %{config | theme: theme, font: %{family: "monospace", size: 24}}})

    # A bigger font means fewer cells: the renderer reports a new grid size.
    assert eventually(fn -> :sys.get_state(window).size != {80, 24} end)
    assert :sys.get_state(window).config.theme.bg == {0, 0, 64}
    assert Port.info(port(window))
  end

  test "a resize from the renderer resizes every tab", %{id: id, window: window} do
    {:ok, second} = Tabs.new_tab()
    renderer(window, <<6, 100::16, 30::16>>)

    assert eventually(fn ->
             Session.size(id) == {100, 30} and Session.size(second) == {100, 30}
           end)

    Session.write(second, "stty size\r")
    assert eventually(fn -> Session.dump(second) =~ ~r/^30 100$/m end)
  end

  test "the program's queries are answered through the PTY", %{id: id} do
    Session.write(id, "printf '\\e[6n'; IFS= read -rsd R pos; echo got${pos#*[}\r")
    assert eventually(fn -> Session.dump(id) =~ ~r/^got\d+;\d+$/m end)
  end

  test "paste and mouse events reach the shell as bytes", %{id: id, window: window} do
    renderer(window, <<8, "echo pasted\n">>)
    assert eventually(fn -> Session.dump(id) =~ ~r/^pasted$/m end)

    # With mouse mode on, a click arrives in the shell as an SGR report;
    # `cat -v` shows it.
    Session.write(id, "printf '\\e[?1000h\\e[?1006h'; cat -v\r")
    assert eventually(fn -> match?(%{mouse: 1000}, :sys.get_state(window).input) end)
    renderer(window, <<9, 0, 0, 4::16, 2::16, 0::16>>)
    Session.write(id, "\r\x04")
    assert eventually(fn -> Session.dump(id) =~ "^[[<0;5;3M" end)
  end

  test "the window follows a restarted screen", %{id: id, window: window} do
    for role <- [:screen, :supervisor] do
      old = GenServer.whereis(Session.via(id, :screen))
      Process.exit(GenServer.whereis(Session.via(id, role)), :kill)

      assert eventually(fn ->
               screen = GenServer.whereis(Session.via(id, :screen))
               screen not in [nil, old] and :sys.get_state(screen).viewer == window
             end),
             "window not viewing the screen after killing #{role}"
    end
  end

  test "stopping the window ends the renderer process", %{window: window} do
    {:os_pid, os_pid} = Port.info(port(window), :os_pid)
    assert File.exists?("/proc/#{os_pid}")
    GenServer.stop(window)
    assert eventually(fn -> not File.exists?("/proc/#{os_pid}") end)
  end

  test "the renderer rejects a malformed message without crashing", %{window: window} do
    ref = Process.monitor(window)
    # A rows message for the right grid size, claiming 5 rows but carrying
    # half of one.
    Port.command(
      port(window),
      <<3, 80::16, 24::16, 0::16, 0::16, 1, 5::16, 0::16, 0::size(400)-unit(8)>>
    )

    # The renderer exits with status 2 (protocol error), not a sanitizer crash.
    assert_receive {:DOWN, ^ref, :process, ^window, {:renderer_exited, 2}}, 5000
  end

  test "updates are pulled one frame at a time", %{id: id, window: window} do
    # A burst of output: the window must never have more than one update
    # waiting for the renderer.
    Session.write(id, "seq 1 20000\r")
    assert eventually(fn -> Session.dump(id) =~ ~r/^20000$/m end)
    assert eventually(fn -> not :sys.get_state(window).awaiting_frame end)
    assert Grid.cell_size() == 10
  end

  defp a ||| b, do: Bitwise.bor(a, b)
end

defmodule Guiltty.WindowTest do
  # Runs the real renderer (the AddressSanitizer + UBSan build) on SDL's
  # offscreen driver, so no window appears. Guiltty.Tabs has a global name,
  # so these tests run one at a time.
  use ExUnit.Case, async: false

  alias Guiltty.{Config, Grid, Session, Tabs, Window}
  alias Guiltty.Session.Screen
  alias Guiltty.Window.Compose

  # Leak checking is off here only: Mesa's offscreen EGL driver leaks a few
  # bytes from a library it unloads before exit. Run the renderer on X11 or
  # Wayland to check leaks.
  @tabs :test_tabs

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

    start_supervised!({Tabs, name: @tabs, session_opts: session_opts})
    window = start_window()
    id = Tabs.active(@tabs)
    assert eventually(fn -> Session.dump(id) =~ ~r/^\$/m end)
    %{id: id, window: window}
  end

  defp start_window do
    spec =
      Supervisor.child_spec({Window, tabs: @tabs, env: @env}, restart: :temporary, id: make_ref())

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
  defp key(window, code, mods), do: renderer(window, <<5, code::32, mods::16, code::32, 1>>)

  # What the Window sends the renderer, from now on, in a file to read back.
  defp record_port(window) do
    path = Path.join(System.tmp_dir!(), "guiltty-port-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)
    {:ok, file} = File.open(path, [:write, :binary])
    :sys.replace_state(window, &%{&1 | recording: file})
    path
  end

  # The real renderer acts on what it's told: a browser, the clipboard. This stops
  # it, from inside the Window (the port's owner), and gives the Window a port
  # that swallows everything and answers nothing, so no more frames come.
  defp drain_renderer(window) do
    :sys.replace_state(window, fn state ->
      Port.close(state.port)
      %{state | port: Port.open({:spawn, "sh -c 'cat >/dev/null'"}, [:binary, packet: 4])}
    end)
  end

  describe "the AI key" do
    defp set_ai(window, command, position \\ :right) do
      :sys.replace_state(window, fn state ->
        %{state | config: %{state.config | ai: %{command: command, position: position}}}
      end)
    end

    defp ai_key(window), do: key(window, ?a, @ctrl ||| @shift)

    defp members(window), do: :sys.get_state(window).members

    defp panes_of_tab(window, id),
      do: Map.get(members(window), :sys.get_state(window).active_tab, [id]) -- [id]

    test "it can be rebound, like any key", %{id: id, window: window} do
      set_ai(window, "cat -v")

      :sys.replace_state(window, fn state ->
        keys = Map.put(state.config.keys, :ai, ["ctrl+shift+y"])
        %{state | config: %{state.config | keys: keys}, bindings: rebound(keys)}
      end)

      key(window, ?a, @ctrl ||| @shift)
      Process.sleep(200)
      assert panes_of_tab(window, id) == []
      key(window, ?y, @ctrl ||| @shift)
      assert eventually(fn -> panes_of_tab(window, id) != [] end)
    end

    defp rebound(keys) do
      for {action, names} <- keys,
          name <- names,
          {:ok, binding} <- [Guiltty.Keymap.parse_key(name)],
          do: {action, binding}
    end

    test "without a command it only says so", %{id: id, window: window} do
      ai_key(window)
      assert eventually(fn -> :sys.get_state(window).flash =~ "no AI tool set" end)
      assert panes_of_tab(window, id) == []
    end

    test "says so when the program isn't there", %{window: window} do
      set_ai(window, "no-such-program-here")
      ai_key(window)
      assert eventually(fn -> :sys.get_state(window).flash =~ "not found" end)
    end

    test "opens beside you, goes back and forth, and stays one pane", %{id: id, window: window} do
      set_ai(window, "cat -v")
      ai_key(window)
      assert eventually(fn -> panes_of_tab(window, id) != [] end)
      [pane] = panes_of_tab(window, id)
      assert eventually(fn -> :sys.get_state(window).active == pane end)

      ai_key(window)
      assert eventually(fn -> :sys.get_state(window).active == id end)
      ai_key(window)
      assert eventually(fn -> :sys.get_state(window).active == pane end)
      assert panes_of_tab(window, id) == [pane]
    end

    test "position: :tab opens a tab of its own", %{id: id, window: window} do
      set_ai(window, "cat -v", :tab)
      ai_key(window)
      assert eventually(fn -> Tabs.active(@tabs) != id end)
      assert eventually(fn -> members(window)[id] == [id] end)
    end

    test "a tool that takes bracketed paste gets what's selected, whole", %{
      id: id,
      window: window
    } do
      set_ai(window, ~S(sh -c "printf '\033[?2004h'; sleep 0.3; exec cat -v"))
      Session.write(id, "printf 'ONE\\nTWO\\n'\r")
      assert eventually(fn -> Session.dump(id) =~ ~r/^TWO$/m end)
      row = Session.dump(id) |> String.split("\n") |> Enum.find_index(&(&1 == "ONE"))
      Screen.select(id, {:start, {row, 0}, 3})
      Screen.select(id, {:extend, {row + 1, 2}})
      Screen.select(id, :finish)

      ai_key(window)
      assert eventually(fn -> panes_of_tab(window, id) != [] end)
      [pane] = panes_of_tab(window, id)
      assert eventually(fn -> Session.dump(pane) =~ "^[[200~ONE" end), Session.dump(pane)
      assert Session.dump(pane) =~ "^[[201~"
      # The screen around it stayed here, and so did a selection nobody needs now.
      refute Session.dump(pane) =~ "printf"
      assert Screen.selection_text(id) == nil
    end

    test "nothing is sent unless it's selected", %{id: id, window: window} do
      set_ai(window, "cat -v")
      Session.write(id, "echo SECRET\r")
      assert eventually(fn -> Session.dump(id) =~ ~r/^SECRET$/m end)
      ai_key(window)
      assert eventually(fn -> panes_of_tab(window, id) != [] end)
      [pane] = panes_of_tab(window, id)
      Process.sleep(300)
      refute Session.dump(pane) =~ "SECRET"
    end

    test "a tool without bracketed paste gets one line, so nothing is sent",
         %{window: window} = context do
      id = context.id
      set_ai(window, "cat -v")
      ai_key(window)
      assert eventually(fn -> panes_of_tab(window, id) != [] end)
      [pane] = panes_of_tab(window, id)
      assert eventually(fn -> :sys.get_state(window).active == pane end)
      :sys.replace_state(window, &%{&1 | ai_paste: %{pane: pane, text: "ONE\nTWO\n  THREE"}})
      send(window, {:ai_paste_late, pane})
      assert eventually(fn -> Session.dump(pane) =~ "ONE TWO THREE" end), Session.dump(pane)
    end
  end

  describe "right click" do
    defp right_click(window, col, row, mods \\ 0),
      do: renderer(window, <<9, 0, 2, col::16, row::16, mods::16, 1>>)

    # The real renderer would put it on a real clipboard: a drain, and the file.
    defp watch_port(window) do
      path = record_port(window)
      drain_renderer(window)
      path
    end

    defp select_word(id, word) do
      row = Session.dump(id) |> String.split("\n") |> Enum.find_index(&(&1 == word))
      Screen.select(id, {:start, {row, 1}, 2})
      Screen.select(id, :finish)
    end

    test "copies what's selected and pastes it at the prompt", %{id: id, window: window} do
      path = watch_port(window)
      Session.write(id, "echo SELECTME\r")
      assert eventually(fn -> Session.dump(id) =~ ~r/^SELECTME$/m end)
      assert select_word(id, "SELECTME") == "SELECTME"

      right_click(window, 0, 0)

      assert eventually(fn -> Session.dump(id) =~ ~r/^\$ SELECTME$/m end), Session.dump(id)
      assert eventually(fn -> File.read!(path) =~ <<18, 0, "SELECTME">> end)
      # Pasted, not run: no Enter.
      refute Session.dump(id) =~ "command not found"
      assert Screen.selection_text(id) == nil
    end

    test "with nothing selected, does nothing", %{id: id, window: window} do
      path = watch_port(window)
      right_click(window, 0, 0)
      Session.write(id, "echo STILL-HERE\r")
      assert eventually(fn -> Session.dump(id) =~ ~r/^STILL-HERE$/m end)
      refute File.read!(path) =~ <<18, 0>>
    end

    test "in a program that asked for the mouse, it's the program's", %{id: id, window: window} do
      Session.write(id, "echo KEEP; printf '\\033[?1000h\\033[?1006h'; cat -v\r")
      assert eventually(fn -> :sys.get_state(window).pane_state[id][:input][:mouse] == 1000 end)
      # Only now: the drain draws no frames, so the window stops taking updates.
      path = watch_port(window)
      select_word(id, "KEEP")
      right_click(window, 2, 1)
      assert eventually(fn -> Session.dump(id) =~ "^[[<2;3;2M" end), Session.dump(id)
      refute File.read!(path) =~ <<18, 0, "KEEP">>
    end
  end

  describe "what programs can ask of the window" do
    test "focus events: CSI I and CSI O, once asked for", %{id: id, window: window} do
      renderer(window, <<26, 0>>)
      Session.write(id, "printf '\\033[?1004h'; cat -v\r")

      assert eventually(fn ->
               :sys.get_state(window).pane_state[id][:input][:focus_events] == true
             end)

      renderer(window, <<26, 1>>)
      assert eventually(fn -> Session.dump(id) =~ "^[[I" end)
      renderer(window, <<26, 0>>)
      assert eventually(fn -> Session.dump(id) =~ "^[[O" end)
    end

    test "focus events follow you between tabs", %{id: id, window: window} do
      Session.write(id, "printf '\\033[?1004h'; cat -v\r")

      assert eventually(fn ->
               :sys.get_state(window).pane_state[id][:input][:focus_events] == true
             end)

      key(window, ?t, @ctrl ||| @shift)
      assert eventually(fn -> Tabs.active(@tabs) != id end)
      assert eventually(fn -> Session.dump(id) =~ "^[[O" end)

      Tabs.switch(@tabs, 0)
      assert eventually(fn -> Tabs.active(@tabs) == id end)
      assert eventually(fn -> Session.dump(id) =~ "^[[I" end)
    end

    test "OSC 52 from the focused pane reaches the clipboard", %{id: id, window: window} do
      path = record_port(window)
      Session.write(id, "printf '\\033]52;c;aGVsbG8=\\a'\r")
      assert eventually(fn -> File.read!(path) =~ <<18, 0, "hello">> end)
    end

    test "OSC 52 from a pane without the keyboard goes nowhere", %{id: id, window: window} do
      path = record_port(window)
      send(window, {:clipboard, :another_pane, {:clipboard, "stolen"}})
      send(window, {:clipboard, id, {:clipboard, "mine"}})
      assert eventually(fn -> File.read!(path) =~ <<18, 0, "mine">> end)
      refute File.read!(path) =~ "stolen"
    end

    test "Ctrl+click opens a link, and only of a kind that should open", %{id: id, window: window} do
      path = record_port(window)
      # The real renderer really opens links, in your real browser. This test
      # only needs to see the message, so it goes down a drain instead.
      drain_renderer(window)

      Session.write(
        id,
        "clear; printf '\\033]8;;https://x.y\\aGO\\033]8;;\\a\\033]8;;javascript:x\\aNO\\033]8;;\\a\\n'\r"
      )

      assert eventually(fn -> Session.dump(id) =~ ~r/^GONO$/m end)
      row = Session.dump(id) |> String.split("\n") |> Enum.find_index(&(&1 == "GONO"))
      {top_x, top_y} = {0, row}

      click = fn col ->
        renderer(window, <<9, 0, 0, top_x + col::16, top_y::16, @ctrl::16, 1>>)
      end

      click.(0)
      assert eventually(fn -> File.read!(path) =~ <<21, "https://x.y">> end)
      click.(2)
      assert eventually(fn -> :sys.get_state(window).flash =~ "not opening a javascript link" end)
      refute File.read!(path) =~ <<21, "javascript">>
    end

    test "Ctrl+click opens a URL in plain text; Ctrl+hover underlines it",
         %{id: id, window: window} do
      path = record_port(window)
      drain_renderer(window)
      screen = GenServer.whereis(Guiltty.Session.via(id, :screen))

      Session.write(id, "clear; echo 'at http://localhost:4000 now'\r")
      assert eventually(fn -> Session.dump(id) =~ ~r/^at http:\/\/localhost:4000 now$/m end)
      row = Session.dump(id) |> String.split("\n") |> Enum.find_index(&(&1 =~ ~r/^at http/))
      mouse = fn kind, button, col, mods -> <<9, kind, button, col::16, row::16, mods::16, 1>> end

      # Moving over it with Ctrl held: underlined. Without Ctrl: not.
      renderer(window, mouse.(2, 3, 5, @ctrl))
      assert eventually(fn -> :sys.get_state(screen).hover == %{pos: {row, 5}, urls?: true} end)
      renderer(window, mouse.(2, 3, 6, 0))
      assert eventually(fn -> :sys.get_state(screen).hover == nil end)

      renderer(window, mouse.(0, 0, 5, @ctrl))
      assert eventually(fn -> File.read!(path) =~ <<21, "http://localhost:4000">> end)
      assert eventually(fn -> :sys.get_state(window).flash =~ "opening http://localhost:4000" end)
    end

    test "the Kitty keyboard protocol, once a program asks", %{id: id, window: window} do
      Session.write(id, "printf '\\033[>1u'; cat -v\r")
      assert eventually(fn -> :sys.get_state(window).pane_state[id][:input][:kitty] == 1 end)
      renderer(window, <<5, ?i::32, @ctrl::16, ?i::32, 1>>)
      assert eventually(fn -> Session.dump(id) =~ "^[[105;5u" end)
    end

    test "a guiltty key's release doesn't reach a program", %{id: id, window: window} do
      Session.write(id, "printf '\\033[>3u'; cat -v\r")
      assert eventually(fn -> :sys.get_state(window).pane_state[id][:input][:kitty] == 3 end)
      renderer(window, <<5, ?f::32, @ctrl + @shift::16, ?F::32, 1>>)
      assert eventually(fn -> :sys.get_state(window).search != nil end)
      renderer(window, <<5, ?f::32, @ctrl + @shift::16, ?F::32, 3>>)
      renderer(window, <<5, 0x1B::32, 0::16, 0x1B::32, 1>>)
      assert eventually(fn -> :sys.get_state(window).search == nil end)
      refute Session.dump(id) =~ "102;"
    end

    test "Ctrl+Shift+Z jumps to the previous prompt", %{id: id, window: window} do
      Session.write(id, "printf '\\033]133;A\\a'; seq 1 100; printf 'LAST\\n'\r")
      assert eventually(fn -> Session.dump(id) =~ ~r/^LAST$/m end)
      key(window, ?z, @ctrl ||| @shift)
      assert eventually(fn -> :sys.get_state(window).scroll > 0 end)
    end

    test "synchronized output: nothing shows until the program is done", %{id: id, window: window} do
      Session.write(id, "clear; printf '\\033[?2026h'; sleep 30\r")

      assert eventually(fn ->
               :sys.get_state(Guiltty.Session.via(id, :screen)).grid.synchronized
             end)

      # A program that never finishes doesn't hold the screen for long.
      assert eventually(fn ->
               not :sys.get_state(Guiltty.Session.via(id, :screen)).grid.synchronized
             end)

      _ = window
    end
  end

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
    assert eventually(fn -> match?({[_, _], _}, Tabs.list(@tabs)) end)
    {_tabs, second} = Tabs.list(@tabs)
    assert second != first
    assert eventually(fn -> :sys.get_state(window).active == second end)

    # Typing goes to the new tab now.
    renderer(window, <<4, "echo in-second">>)
    key(window, 0x0D, 0)
    assert eventually(fn -> Session.dump(second) =~ ~r/^in-second$/m end)
    refute Session.dump(first) =~ "in-second"

    key(window, ?w, @ctrl ||| @shift)
    assert eventually(fn -> Tabs.list(@tabs) == {[{first, Screen.title(first)}], first} end)
    assert eventually(fn -> :sys.get_state(window).active == first end)
  end

  test "Ctrl+PgDn and a click on the tab bar switch tabs", %{id: first, window: window} do
    {:ok, second} = Tabs.new_tab(@tabs)
    key(window, 0x4000004E, @ctrl)
    assert eventually(fn -> Tabs.active(@tabs) == first end)
    renderer(window, <<16, 1>>)
    assert eventually(fn -> Tabs.active(@tabs) == second end)
  end

  test "closing the window leaves the tabs running; a new window shows them", %{
    id: id,
    window: window
  } do
    Session.write(id, "echo still-here\r")
    {:ok, second} = Tabs.new_tab(@tabs)
    {:os_pid, os_pid} = Port.info(port(window), :os_pid)

    GenServer.stop(window)
    assert eventually(fn -> not File.exists?("/proc/#{os_pid}") end)
    assert Tabs.list(@tabs) |> elem(0) |> length() == 2
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

  test "every tab style and tab colors reach the renderer, live", %{window: window} do
    {:ok, _second} = Tabs.new_tab(@tabs)
    config = Config.defaults()
    theme = %{config.theme | tab_bar: {0x28, 0x2A, 0x36}, tab_accent: {0xFF, 0x79, 0xC6}}

    for style <- [:powerline, :rounded, :minimal, :separators, :flat] do
      send(window, {:config, %{config | tab_style: style, theme: theme}})
      assert eventually(fn -> :sys.get_state(window).config.tab_style == style end)
      # The debug renderer runs under ASan and UBSan: drawing each style
      # without a report means it's still there.
      assert Port.info(port(window)), "the renderer died drawing #{style} tabs"
    end
  end

  test "a resize from the renderer resizes every tab", %{id: id, window: window} do
    {:ok, second} = Tabs.new_tab(@tabs)
    renderer(window, <<6, 100::16, 30::16, 9::16, 18::16>>)

    assert eventually(fn ->
             Session.size(id) == {100, 30} and Session.size(second) == {100, 30}
           end)

    Session.write(second, "stty size\r")
    assert eventually(fn -> Session.dump(second) =~ ~r/^30 100$/m end)

    # The cell size reached the screen too: it answers CSI 16 t with it.
    Session.write(second, "printf '\\e[16t'; IFS= read -rsd t px; echo cell${px#*[}\r")
    assert eventually(fn -> Session.dump(second) =~ ~r/^cell6;18;9$/m end)
  end

  test "the renderer's first resize gives the tabs the cell size", %{id: id, window: window} do
    # The real renderer sends one at startup, even when the setup's grid
    # already fits: the cell size is news.
    assert eventually(fn -> screen_state(id).grid.cell_pixels != nil end)
    assert Port.info(port(window))
  end

  test "the program's queries are answered through the PTY", %{id: id} do
    Session.write(id, "printf '\\e[6n'; IFS= read -rsd R pos; echo got${pos#*[}\r")
    # Not anchored at the start: an answer that beats `read` turning echo off
    # shows on the screen first, on the same line.
    assert eventually(fn -> Session.dump(id) =~ ~r/got\d+;\d+$/m end)
  end

  test "paste and mouse events reach the shell as bytes", %{id: id, window: window} do
    renderer(window, <<8, "echo pasted\n">>)
    assert eventually(fn -> Session.dump(id) =~ ~r/^pasted$/m end)

    # With mouse mode on, a click arrives in the shell as an SGR report;
    # `cat -v` shows it.
    Session.write(id, "printf '\\e[?1000h\\e[?1006h'; cat -v\r")
    assert eventually(fn -> match?(%{mouse: 1000}, :sys.get_state(window).input) end)
    renderer(window, <<9, 0, 0, 4::16, 2::16, 0::16, 1>>)
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

  test "closing the window quits: every tab ends, then Tabs (and guiltty)", %{window: window} do
    {:ok, _second} = Tabs.new_tab(@tabs)
    tabs = Process.whereis(@tabs)
    ref = Process.monitor(tabs)

    # What the renderer sends when you close the window: exit status 0.
    send(window, {port(window), {:exit_status, 0}})
    assert_receive {:DOWN, ^ref, :process, ^tabs, {:shutdown, :last_tab_closed}}, 5000
  end

  test "Ctrl+Shift+B on a local tab asks first; pressing again adds it as local", %{
    id: id,
    window: window
  } do
    key(window, ?b, @ctrl ||| @shift)

    assert eventually(fn ->
             match?({:warning, "this tab is local (bash)" <> _}, :sys.get_state(window).status)
           end)

    assert :sys.get_state(window).group == %{}

    key(window, ?b, @ctrl ||| @shift)
    assert eventually(fn -> :sys.get_state(window).group == %{id => :local} end)
    assert :sys.get_state(window).status == {:normal, "📡 broadcast: 1 tab (1 local)"}
  end

  test "Ctrl+Shift+L locks a tab: it shows a lock, and outlives the window", %{
    id: id,
    window: window
  } do
    {:ok, second} = Tabs.new_tab(@tabs)
    :ok = Tabs.switch(@tabs, 0)
    key(window, ?l, @ctrl ||| @shift)
    assert eventually(fn -> MapSet.member?(:sys.get_state(window).locked, id) end)

    ref = Process.monitor(window)
    send(window, {port(window), {:exit_status, 0}})
    assert_receive {:DOWN, ^ref, :process, ^window, {:shutdown, :window_closed}}, 5000

    # The unlocked tab ended; the locked one runs on, for the next window.
    assert eventually(fn -> Tabs.list(@tabs) |> elem(0) |> Enum.map(&elem(&1, 0)) == [id] end)
    refute second in (Tabs.list(@tabs) |> elem(0) |> Enum.map(&elem(&1, 0)))
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
      <<3, 80::16, 24::16, 0::16, 0::16, 1, 0, 0::16, 5::16, 0::16, 0::size(560)-unit(8)>>
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
    assert Grid.cell_size() == 14
  end

  defp screen_state(id), do: :sys.get_state(GenServer.whereis(Session.via(id, :screen)))

  defp mouse(window, kind, button, col, row, clicks \\ 1),
    do: renderer(window, <<9, kind, button, col::16, row::16, 0::16, clicks>>)

  test "Unicode reaches the renderer: clusters and wide characters", %{id: id, window: window} do
    Session.write(
      id,
      "printf '\\xe6\\x97\\xa5\\xe6\\x9c\\xac e\\xcc\\x81 \\xf0\\x9f\\x87\\xaf\\xf0\\x9f\\x87\\xb5 ok\\n'\r"
    )

    assert eventually(fn -> Session.dump(id) =~ ~r/^日本 e\x{301} 🇯🇵 ok$/mu end)
    assert eventually(fn -> not :sys.get_state(window).awaiting_frame end)
    assert screen_state(id).sent_clusters > 0x110000
    assert Port.info(port(window))
  end

  test "the wheel scrolls back when the program doesn't want the mouse", %{id: id, window: window} do
    Session.write(id, "seq 1 100\r")
    assert eventually(fn -> Session.dump(id) =~ ~r/^100$/m end)
    mouse(window, 3, 0, 0, 0)
    assert eventually(fn -> screen_state(id).scroll == 3 end)
    renderer(window, <<6, 80::16, 24::16, 9::16, 18::16>>)

    # Shift+PgUp goes a page further; typing brings the view back.
    key(window, 0x4000004B, @shift)
    assert eventually(fn -> screen_state(id).scroll == 26 end)
    renderer(window, <<4, "x">>)
    assert eventually(fn -> screen_state(id).scroll == 0 end)
  end

  test "a selection follows its text as it scrolls, and goes when the text changes", %{
    id: id,
    window: window
  } do
    Session.write(id, "clear; echo keep-me\r")
    assert eventually(fn -> Session.dump(id) =~ ~r/^keep-me$/m end)
    row = Session.dump(id) |> String.split("\n") |> Enum.find_index(&(&1 == "keep-me"))

    mouse(window, 0, 0, 0, row)
    mouse(window, 2, 0, 6, row)
    mouse(window, 1, 0, 6, row)
    assert eventually(fn -> Screen.selection_text(id) == "keep-me" end)

    # Output scrolls it up, into the scrollback: same text, still selected.
    Session.write(id, "seq 1 40\r")
    assert eventually(fn -> Session.dump(id) =~ ~r/^40$/m end)
    assert Screen.selection_text(id) == "keep-me"

    # clear erases it: the selection goes, and with it the highlight.
    Session.write(id, "clear\r")
    assert eventually(fn -> Screen.selection_text(id) == nil end)

    assert eventually(fn ->
             not :sys.get_state(GenServer.whereis(Session.via(id, :screen))).decorated
           end)
  end

  test "dragging selects text; a plain click clears it", %{id: id, window: window} do
    Session.write(id, "clear; echo select-me\r")
    assert eventually(fn -> Session.dump(id) =~ ~r/^select-me$/m end)

    {row, _} =
      Enum.find(Enum.with_index(String.split(Session.dump(id), "\n")), fn {l, _} ->
        l == "select-me"
      end)
      |> then(fn {_l, i} -> {i, 0} end)

    mouse(window, 0, 0, 0, row)
    mouse(window, 2, 0, 5, row)
    mouse(window, 1, 0, 5, row)
    assert eventually(fn -> Screen.selection_text(id) == "select" end)

    # A double click takes the word.
    mouse(window, 0, 0, 2, row, 2)
    mouse(window, 1, 0, 2, row, 2)
    assert eventually(fn -> Screen.selection_text(id) == "select-me" end)

    mouse(window, 0, 0, 1, row)
    mouse(window, 1, 0, 1, row)
    assert eventually(fn -> Screen.selection_text(id) == nil end)
  end

  test "search: Ctrl+Shift+F, type, Enter for older, Escape to end", %{id: id, window: window} do
    Session.write(id, "echo needle-1; seq 1 60; echo needle-2\r")
    assert eventually(fn -> Session.dump(id) =~ ~r/^needle-2$/m end)

    key(window, ?f, @ctrl ||| @shift)
    renderer(window, <<4, "needle">>)

    assert eventually(fn ->
             match?(%{search: %{query: "needle", match: {_, 0, 5}}}, screen_state(id))
           end)

    {n, 0, 5} = screen_state(id).search.match

    # Typing goes to the query, not the shell.
    refute Session.dump(id) =~ "$ needle"

    key(window, 0x0D, 0)

    assert eventually(fn ->
             match?({older, 0, 5} when older < n, screen_state(id).search.match)
           end)

    assert screen_state(id).scroll > 0

    key(window, 0x1B, 0)
    assert eventually(fn -> screen_state(id).search == nil end)
    assert :sys.get_state(window).search == nil
  end

  test "a config error that arrives before the handshake waits for it" do
    # A Window that hears about the error during init, before the renderer
    # said hello, must not send it early: the renderer would refuse it.
    spec =
      Supervisor.child_spec({Window, tabs: @tabs, env: @env}, restart: :temporary, id: :early)

    window = start_supervised!(spec)
    send(window, {:config_error, "config.exs: broken"})
    assert eventually(fn -> :sys.get_state(window).ready end), "no handshake"

    assert eventually(fn ->
             :sys.get_state(window).status == {:warning, "⚠ config.exs: broken"}
           end)

    assert Port.info(port(window))
  end

  test "a Vulkan renderer that can't start falls back to OpenGL, and says so", %{
    window: window
  } do
    GenServer.stop(window)
    on_exit(fn -> Application.delete_env(:guiltty, :vulkan_failed) end)

    # No Vulkan driver at all: vkCreateInstance fails, the renderer exits 1
    # before its hello.
    env = [
      {~c"VK_ICD_FILENAMES", ~c"/nonexistent.json"},
      {~c"VK_DRIVER_FILES", ~c"/nonexistent.json"} | @env
    ]

    opts = [tabs: @tabs, env: env, renderer: "guiltty_vk-dbg"]
    spec = Supervisor.child_spec({Window, opts}, restart: :temporary, id: :vulkan)
    window = start_supervised!(spec)

    # It says hello before it fails (the hello comes before its window):
    # wait for the second handshake, with OpenGL.
    assert eventually(fn ->
             state = :sys.get_state(window)
             state.renderer == "guiltty_gl-dbg" and state.ready and state.drawn
           end),
           "no fallback"

    assert {:warning, "Vulkan couldn't start" <> _} = :sys.get_state(window).status
    assert Application.get_env(:guiltty, :vulkan_failed)
  end

  test "an image a program shows reaches the renderer, and leaves it when deleted", %{
    id: id,
    window: window
  } do
    # A 1 x 1 red pixel, Kitty graphics, from the shell.
    Session.write(id, "printf '\\e_Ga=T,f=24,s=1,v=1;/wAA\\e\\\\'\r")
    assert eventually(fn -> MapSet.size(:sys.get_state(window).sent_images) == 1 end)

    Session.write(id, "printf '\\e_Ga=d,d=A\\e\\\\'\r")
    assert eventually(fn -> MapSet.size(:sys.get_state(window).sent_images) == 0 end)
    assert Port.info(port(window)), "the renderer died"
  end

  test "the editor for the config: $VISUAL, else $EDITOR, split like a shell; nil if not installed" do
    tail = System.find_executable("tail")
    assert Window.editor(%{"VISUAL" => "tail -f", "EDITOR" => "nano"}) == {tail, ["-f"]}
    assert Window.editor(%{"VISUAL" => "", "EDITOR" => "tail -n '1 0'"}) == {tail, ["-n", "1 0"]}
    assert Window.editor(%{"EDITOR" => "no-such-editor-here"}) == nil
    assert Window.editor(%{}) == nil
  end

  @tag :tmp_dir
  test "Ctrl+, opens the config in a new tab running $VISUAL", %{window: window, tmp_dir: dir} do
    config = Path.join(dir, "config.exs")
    File.write!(config, "[font: [size: 15]] # opened in the editor\n")
    System.put_env("GUILTTY_CONFIG", config)
    System.put_env("VISUAL", "tail -f")

    on_exit(fn ->
      System.delete_env("GUILTTY_CONFIG")
      System.delete_env("VISUAL")
    end)

    key(window, ?,, @ctrl)
    assert eventually(fn -> length(elem(Tabs.list(@tabs), 0)) == 2 end)
    editor_tab = Tabs.active(@tabs)
    assert eventually(fn -> Session.dump(editor_tab) =~ "# opened in the editor" end)
  end

  describe "split panes" do
    # The window's grid as text, row by row, as the Window stitched it.
    defp window_text(window) do
      window
      |> :sys.get_state()
      |> Map.fetch!(:compose)
      |> Compose.all_rows()
      |> Enum.map(fn {_i, row} ->
        for <<g::32, _::binary-size(10) <- row>>, into: "", do: <<g::utf8>>
      end)
    end

    test "Ctrl+Shift+O splits: two shells side by side, typing goes to the new one", %{
      id: id,
      window: window
    } do
      renderer(window, <<6, 81::16, 24::16, 9::16, 18::16>>)
      assert eventually(fn -> Session.size(id) == {81, 24} end)
      key(window, ?o, @ctrl ||| @shift)
      assert eventually(fn -> :sys.get_state(window).active != id end)
      right = :sys.get_state(window).active
      assert Session.size(id) == {40, 24}
      assert eventually(fn -> Session.dump(right) =~ ~r/^\$/m end)

      renderer(window, <<4, "echo in-the-right-one">>)
      key(window, 0x0D, 0)
      assert eventually(fn -> Session.dump(right) =~ ~r/^in-the-right-one$/m end)
      refute Session.dump(id) =~ "in-the-right-one"

      # Both prompts, with the separator between them.
      assert eventually(fn -> hd(window_text(window)) =~ ~r/^\$ +│\$ echo in-the-right-one/ end)
    end

    test "a click focuses the pane under it; Ctrl+Shift+arrows too", %{id: id, window: window} do
      renderer(window, <<6, 81::16, 24::16, 9::16, 18::16>>)
      assert eventually(fn -> Session.size(id) == {81, 24} end)
      key(window, ?o, @ctrl ||| @shift)
      assert eventually(fn -> :sys.get_state(window).active != id end)
      right = :sys.get_state(window).active

      # Column 5 is the left pane (columns 0-39; 40 is the separator).
      mouse(window, 0, 0, 5, 3)
      mouse(window, 1, 0, 5, 3)
      assert eventually(fn -> :sys.get_state(window).active == id end)

      key(window, 0x4000004F, @ctrl ||| @shift)
      assert eventually(fn -> :sys.get_state(window).active == right end)
      assert Port.info(port(window))
    end
  end

  test "a config error shows as a warning until a config loads", %{window: window} do
    send(window, {:config_error, "config.exs:4: theme: unknown name"})

    assert eventually(fn ->
             :sys.get_state(window).status == {:warning, "⚠ config.exs:4: theme: unknown name"}
           end)

    send(window, {:config, Config.defaults()})
    assert eventually(fn -> :sys.get_state(window).status == {:normal, ""} end)
    assert Port.info(port(window))
  end

  test "a paused broadcast shows over a config error, which comes back after", %{
    id: id,
    window: window
  } do
    send(window, {:config_error, "config.exs:4: theme: unknown name"})

    assert eventually(fn ->
             :sys.get_state(window).status == {:warning, "⚠ config.exs:4: theme: unknown name"}
           end)

    # What Tabs sends when the group's check finds tab 1's ssh gone.
    info = Tabs.attach_window(@tabs, self())
    send(window, {:tabs, %{info | group: %{id => "web-01"}, lost: MapSet.new([id])}})

    assert eventually(fn ->
             :sys.get_state(window).status ==
               {:warning, "⚠ broadcast paused: tab 1 (web-01) disconnected"}
           end)

    send(window, {:tabs, info})

    assert eventually(fn ->
             :sys.get_state(window).status == {:warning, "⚠ config.exs:4: theme: unknown name"}
           end)
  end

  test "Ctrl+Shift+/ opens the cheatsheet; typing doesn't reach the shell; Esc closes it", %{
    id: id,
    window: window
  } do
    key(window, ?/, @ctrl ||| @shift)

    assert eventually(fn ->
             match?(%{lines: [_ | _], top: 0}, :sys.get_state(window).cheatsheet)
           end)

    renderer(window, <<4, "echo leaked">>)
    key(window, 0x0D, 0)
    Process.sleep(200)
    refute Session.dump(id) =~ "leaked"

    # j scrolls when the sheet is taller than the window (80x24 here).
    lines = length(:sys.get_state(window).cheatsheet.lines)
    if lines > 24, do: renderer(window, <<4, "j">>)
    if lines > 24, do: assert(eventually(fn -> :sys.get_state(window).cheatsheet.top == 1 end))

    key(window, 0x1B, 0)
    assert eventually(fn -> :sys.get_state(window).cheatsheet == nil end)
    renderer(window, <<4, "echo back">>)
    key(window, 0x0D, 0)
    assert eventually(fn -> Session.dump(id) =~ ~r/^back$/m end)
    assert Port.info(port(window))
  end

  test "Ctrl+= zooms in: bigger cells, fewer of them", %{window: window} do
    key(window, ?=, @ctrl)
    assert eventually(fn -> :sys.get_state(window).zoom == 1 end)
    assert eventually(fn -> :sys.get_state(window).size != {80, 24} end)
    key(window, ?0, @ctrl)
    assert eventually(fn -> :sys.get_state(window).zoom == 0 end)
  end

  defp ids, do: Tabs.list(@tabs) |> elem(0) |> Enum.map(&elem(&1, 0))

  test "closing a tab that runs a program asks first; a second press closes it", %{
    window: window
  } do
    {:ok, busy} = Tabs.new_tab(@tabs)
    assert eventually(fn -> :sys.get_state(window).active == busy end)
    Session.write(busy, "sleep 30\r")
    assert eventually(fn -> Guiltty.Session.Pty.busy(busy) == "sleep" end)

    key(window, ?w, @ctrl ||| @shift)

    assert eventually(fn ->
             :sys.get_state(window).status ==
               {:warning, "sleep is running: press again to close"}
           end)

    assert busy in ids()

    key(window, ?w, @ctrl ||| @shift)
    assert eventually(fn -> busy not in ids() end)
  end

  test "a tab at its prompt closes at once", %{id: id, window: window} do
    {:ok, idle} = Tabs.new_tab(@tabs)
    assert eventually(fn -> :sys.get_state(window).active == idle end)
    assert eventually(fn -> Guiltty.Session.Pty.busy(idle) == nil end)
    key(window, ?w, @ctrl ||| @shift)
    assert eventually(fn -> ids() == [id] end)
  end

  test "Ctrl+Shift+R renames the tab: typing edits the name, Enter sets it", %{
    id: id,
    window: window
  } do
    key(window, ?r, @ctrl ||| @shift)
    assert eventually(fn -> :sys.get_state(window).rename == %{text: ""} end)

    renderer(window, <<4, "prodd">>)
    key(window, Guiltty.Keymap.key(:backspace), 0)
    assert eventually(fn -> :sys.get_state(window).status == {:normal, "rename tab: prod"} end)

    # Typing goes to the name, not the shell.
    refute Session.dump(id) =~ "prod"

    key(window, 0x0D, 0)
    assert eventually(fn -> Tabs.list(@tabs) == {[{id, "prod"}], id} end)
    assert :sys.get_state(window).rename == nil

    # Escape leaves the name as it was.
    key(window, ?r, @ctrl ||| @shift)
    renderer(window, <<4, "-x">>)
    key(window, 0x1B, 0)
    assert eventually(fn -> :sys.get_state(window).rename == nil end)
    assert Tabs.list(@tabs) == {[{id, "prod"}], id}
  end

  test "Ctrl+Shift+PgUp and PgDn move the tab", %{id: first, window: window} do
    {:ok, second} = Tabs.new_tab(@tabs)
    assert eventually(fn -> :sys.get_state(window).active == second end)

    key(window, Guiltty.Keymap.key(:page_up), @ctrl ||| @shift)
    assert eventually(fn -> ids() == [second, first] end)
    key(window, Guiltty.Keymap.key(:page_down), @ctrl ||| @shift)
    assert eventually(fn -> ids() == [first, second] end)
  end

  test "Ctrl+Shift+K clears the scrollback and keeps the screen", %{id: id, window: window} do
    Session.write(id, "seq 1 100; echo kept\r")
    assert eventually(fn -> Session.dump(id) =~ ~r/^kept$/m end)
    assert Grid.scrollback_size(screen_state(id).grid) > 0

    key(window, ?k, @ctrl ||| @shift)
    assert eventually(fn -> Grid.scrollback_size(screen_state(id).grid) == 0 end)
    assert Session.dump(id) =~ ~r/^kept$/m
  end

  test "GUILTTY_RENDERER wins over the config's renderer" do
    assert Window.renderer_setting("gl", :vulkan) == :gl
    assert Window.renderer_setting("vulkan", :gl) == :vulkan
    assert Window.renderer_setting(nil, :gl) == :gl
    assert Window.renderer_setting("", :vulkan) == :vulkan
    assert Window.renderer_setting("metal", :vulkan) == :vulkan
  end

  defp a ||| b, do: Bitwise.bor(a, b)
end

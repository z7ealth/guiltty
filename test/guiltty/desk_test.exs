defmodule Guiltty.DeskTest do
  # Several windows, each its own desk: tabs, locks and lifetime never mix.
  # Desks, Sessions and Lifeline have global names: not async.
  use ExUnit.Case, async: false

  alias Guiltty.{Desk, Lifeline, Tabs}

  @env [
    {~c"SDL_VIDEO_DRIVER", ~c"offscreen"},
    {~c"ASAN_OPTIONS", ~c"detect_leaks=0"},
    {~c"UBSAN_OPTIONS", ~c"halt_on_error=1:print_stacktrace=1"}
  ]

  setup do
    start_supervised!({DynamicSupervisor, name: Guiltty.Sessions, strategy: :one_for_one})
    start_supervised!({DynamicSupervisor, name: Guiltty.Desks, strategy: :one_for_one})
    # Restart: :temporary, so the test sees it stop instead of restarting.
    lifeline = start_supervised!(Supervisor.child_spec(Lifeline, restart: :temporary))
    %{lifeline: lifeline}
  end

  defp open_desk do
    session_opts = [
      shell: System.find_executable("bash"),
      args: ["--norc", "--noprofile"],
      env: %{"PS1" => "$ "}
    ]

    {:ok, desk} = Lifeline.open(window: [env: @env], session_opts: session_opts)
    desk
  end

  defp ids(desk), do: Desk.tabs(desk) |> Tabs.list() |> elem(0) |> Enum.map(&elem(&1, 0))

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

  test "two windows have their own tabs" do
    a = open_desk()
    b = open_desk()
    assert [a_first] = ids(a)
    assert [b_first] = ids(b)
    assert a_first != b_first

    {:ok, a_second} = Tabs.new_tab(Desk.tabs(a))
    assert ids(a) == [a_first, a_second]
    assert ids(b) == [b_first]

    # Locking is per window too.
    :ok = Tabs.toggle_lock(Desk.tabs(a), a_second)
    assert MapSet.equal?(:sys.get_state(Desk.tabs(a)).locked, MapSet.new([a_second]))
    assert MapSet.size(:sys.get_state(Desk.tabs(b)).locked) == 0
  end

  test "closing one window's tabs ends that desk, not the other", %{lifeline: lifeline} do
    a = open_desk()
    b = open_desk()
    a_pid = GenServer.whereis(Desk.name(a))
    ref = Process.monitor(a_pid)

    :ok = Tabs.close_unlocked(Desk.tabs(a))
    assert_receive {:DOWN, ^ref, :process, ^a_pid, _}, 5_000

    assert [_] = ids(b)
    assert Process.alive?(lifeline)
    assert Desk.all() == [b]
  end

  test "a crashed Tabs takes back its own sessions, and only those" do
    a = open_desk()
    b = open_desk()
    {:ok, _} = Tabs.new_tab(Desk.tabs(a))
    a_ids = ids(a)
    b_ids = ids(b)

    old = GenServer.whereis(Desk.tabs(a))
    Process.exit(old, :kill)

    assert eventually(fn ->
             new = GenServer.whereis(Desk.tabs(a))
             new not in [nil, old] and ids(a) == a_ids
           end)

    assert ids(b) == b_ids
  end

  defp window(desk) do
    Supervisor.which_children(Desk.name(desk))
    |> Enum.find_value(fn
      {Guiltty.Window, pid, _, _} -> is_pid(pid) && pid
      _ -> nil
    end)
  end

  defp close_window(desk) do
    pid = window(desk)
    ref = Process.monitor(pid)
    # What the Window does when the renderer exits 0 (the user closed it).
    send(pid, {:sys.get_state(pid).port, {:exit_status, 0}})
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
  end

  test "a window closed with locked tabs comes back as it was, before any new one" do
    a = open_desk()
    {:ok, locked} = Tabs.new_tab(Desk.tabs(a))
    :ok = Tabs.toggle_lock(Desk.tabs(a), locked)

    close_window(a)
    # The unlocked tab closes; the locked one keeps running, windowless.
    assert eventually(fn -> ids(a) == [locked] end)
    assert Desk.windowless?(a)

    # Ctrl+Shift+N always opens a fresh window...
    {:ok, fresh} = Lifeline.open(window: [env: @env], fresh: true)
    assert fresh != a
    assert Desk.windowless?(a)

    # ...but the launcher brings the closed one back first, with its tabs.
    {:ok, ^a} = Lifeline.open(window: [env: @env])
    refute Desk.windowless?(a)
    assert eventually(fn -> :sys.get_state(window(a)).ready end)
    assert :sys.get_state(window(a)).active == locked
  end

  test "Ctrl+Shift+N in a window opens another, independent one" do
    a = open_desk()
    pid = window(a)
    assert eventually(fn -> :sys.get_state(pid).ready end)

    # SDL's keycode for n, with Ctrl and Shift held.
    send(pid, {:sys.get_state(pid).port, {:data, <<5, ?n::32, 0x0041::16>>}})

    assert eventually(fn -> length(Desk.all()) == 2 end)
    [^a, b] = Enum.sort(Desk.all())
    assert ids(b) != ids(a)
  end

  test "guiltty's Lifeline stops when the last window is gone", %{lifeline: lifeline} do
    a = open_desk()
    b = open_desk()
    ref = Process.monitor(lifeline)

    :ok = Tabs.close_unlocked(Desk.tabs(a))
    refute_receive {:DOWN, ^ref, _, _, _}, 1_000

    :ok = Tabs.close_unlocked(Desk.tabs(b))
    assert_receive {:DOWN, ^ref, :process, ^lifeline, {:shutdown, :last_desk_closed}}, 5_000
  end

  test "a window's display reaches its tabs' shells" do
    session_opts = [
      shell: System.find_executable("bash"),
      args: ["--norc", "--noprofile"],
      env: %{"PS1" => "$ "}
    ]

    window = [env: [{~c"DISPLAY", ~c":42"}, {~c"XAUTHORITY", ~c"/tmp/xa"} | @env]]
    {:ok, desk} = Lifeline.open(window: window, session_opts: session_opts)
    [id] = ids(desk)

    Guiltty.Session.write(id, "echo shell-sees-$DISPLAY-$XAUTHORITY\r")
    assert eventually(fn -> Guiltty.Session.dump(id) =~ "shell-sees-:42-/tmp/xa" end)
  end
end

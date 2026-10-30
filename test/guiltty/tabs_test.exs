defmodule Guiltty.TabsTest do
  # Guiltty.Tabs and Guiltty.Sessions have global names: not async.
  use ExUnit.Case, async: false

  alias Guiltty.{Session, Tabs}
  alias Guiltty.Session.Pty

  setup do
    start_supervised!({DynamicSupervisor, name: Guiltty.Sessions, strategy: :one_for_one})

    session_opts = [
      shell: System.find_executable("bash"),
      args: ["--norc", "--noprofile"],
      env: %{"PS1" => "$ "}
    ]

    tabs = start_supervised!({Tabs, session_opts: session_opts})
    %{tabs: tabs}
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

  defp ids, do: Tabs.list() |> elem(0) |> Enum.map(&elem(&1, 0))

  test "starts with one tab" do
    assert [id] = ids()
    assert Tabs.active() == id
  end

  test "new tabs open after the active one and become active" do
    [first] = ids()
    {:ok, second} = Tabs.new_tab()
    {:ok, third} = Tabs.new_tab()
    assert ids() == [first, second, third]
    assert Tabs.active() == third

    :ok = Tabs.switch(0)
    {:ok, fourth} = Tabs.new_tab()
    assert ids() == [first, fourth, second, third]
  end

  test "switching wraps around" do
    [first] = ids()
    {:ok, second} = Tabs.new_tab()
    :ok = Tabs.switch(:next)
    assert Tabs.active() == first
    :ok = Tabs.switch(:prev)
    assert Tabs.active() == second
    :ok = Tabs.switch(7)
    assert Tabs.active() == second
  end

  test "a tab ends when its shell exits; the one to its right takes over" do
    [first] = ids()
    {:ok, second} = Tabs.new_tab()
    {:ok, third} = Tabs.new_tab()
    :ok = Tabs.switch(1)
    Session.write(second, "exit\r")
    assert eventually(fn -> ids() == [first, third] end)
    assert Tabs.active() == third
  end

  test "titles come from the program" do
    [id] = ids()
    Session.write(id, "printf '\\e]2;my title\\a'\r")
    assert eventually(fn -> Tabs.list() == {[{id, "my title"}], id} end)
  end

  test "windows hear about every change" do
    {tabs, active, locked} = Tabs.attach_window(self())
    assert [{^active, _}] = tabs
    assert MapSet.size(locked) == 0
    {:ok, second} = Tabs.new_tab()
    assert_receive {:tabs, [{^active, _}, {^second, _}], ^second, _locked}
  end

  test "the last tab closing stops Tabs (and so guiltty)", %{tabs: tabs} do
    ref = Process.monitor(tabs)
    [id] = ids()
    Session.write(id, "exit\r")
    assert_receive {:DOWN, ^ref, :process, ^tabs, {:shutdown, :last_tab_closed}}, 5000
  end

  test "a crashed Tabs takes the running sessions back", %{tabs: tabs} do
    [first] = ids()
    {:ok, second} = Tabs.new_tab()
    Process.exit(tabs, :kill)
    assert eventually(fn -> Process.whereis(Tabs) not in [nil, tabs] end)
    assert ids() == [first, second]
    {:ok, third} = Tabs.new_tab()
    assert third > second
  end

  test "a crashed session comes back as the same tab" do
    [id] = ids()
    sup = GenServer.whereis(Session.via(id, :supervisor))
    Process.exit(sup, :kill)

    assert eventually(fn ->
             pid = GenServer.whereis(Session.via(id, :supervisor))
             pid not in [nil, sup]
           end)

    Process.sleep(200)
    assert ids() == [id]
  end

  test "a new tab starts in the active tab's directory" do
    [first] = ids()
    Session.write(first, "cd /usr/share\r")
    assert eventually(fn -> Pty.cwd(first) == "/usr/share" end)
    {:ok, second} = Tabs.new_tab()
    Session.write(second, "pwd\r")
    assert eventually(fn -> Session.dump(second) =~ ~r/^\/usr\/share$/m end)
  end

  test "closing the unlocked tabs keeps the locked ones" do
    Tabs.attach_window(self())
    [first] = ids()
    {:ok, second} = Tabs.new_tab()
    {:ok, third} = Tabs.new_tab()

    :ok = Tabs.toggle_lock(second)
    assert MapSet.equal?(:sys.get_state(Tabs).locked, MapSet.new([second]))

    :ok = Tabs.close_unlocked()
    assert eventually(fn -> ids() == [second] end)
    refute first in ids() or third in ids()

    # Unlocking works too.
    :ok = Tabs.toggle_lock(second)
    assert MapSet.size(:sys.get_state(Tabs).locked) == 0
  end

  test "resize applies to every tab and to new ones" do
    [first] = ids()
    {:ok, second} = Tabs.new_tab()
    :ok = Tabs.resize(100, 30)
    assert Session.size(first) == {100, 30}
    assert Session.size(second) == {100, 30}
    {:ok, third} = Tabs.new_tab()
    assert Session.size(third) == {100, 30}
  end
end

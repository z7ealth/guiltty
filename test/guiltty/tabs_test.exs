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
    %{list: tabs, active: active, locked: locked} = Tabs.attach_window(self())
    assert [{^active, _}] = tabs
    assert MapSet.size(locked) == 0
    {:ok, second} = Tabs.new_tab()
    assert_receive {:tabs, %{list: [{^active, _}, {^second, _}], active: ^second}}
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

  describe "broadcast" do
    # cat stands in for ssh: it's in the foreground until it ends (Ctrl+D),
    # and then the shell is again, just like after a dropped connection.
    defp run_cat(id) do
      Session.write(id, "cat\r")
      assert eventually(fn -> match?({_, "cat"}, Pty.foreground(id)) end)
    end

    test "the host of an ssh command line, for messages" do
      assert Tabs.ssh_host(~w(ssh web-01)) == "web-01"
      assert Tabs.ssh_host(~w(ssh -p 2222 admin@web-02 uptime)) == "web-02"
      assert Tabs.ssh_host(~w(ssh -A -i ~/.ssh/id -o StrictHostKeyChecking=no db.lan)) == "db.lan"
      assert Tabs.ssh_host(~w(ssh)) == nil
    end

    test "only tabs running an allowed program can join" do
      [first] = ids()
      assert eventually(fn -> match?({_, "bash"}, Pty.foreground(first)) end)
      assert {:error, {:not_allowed, "bash"}} = Tabs.toggle_broadcast(first, ["cat"])
      run_cat(first)
      assert {:ok, :joined} = Tabs.toggle_broadcast(first, ["cat"])
      assert {:ok, :left} = Tabs.toggle_broadcast(first, ["cat"])
    end

    test "typing in one goes to all; a lost one pauses it, leaving resumes it" do
      Tabs.attach_window(self())
      [first] = ids()
      {:ok, second} = Tabs.new_tab()
      run_cat(first)
      run_cat(second)
      {:ok, :joined} = Tabs.toggle_broadcast(first, ["cat"])
      {:ok, :joined} = Tabs.toggle_broadcast(second, ["cat"])

      assert :sent = Tabs.send_input(first, "to-both\r")
      assert eventually(fn -> Session.dump(first) =~ ~r/^to-both$/m end)
      assert eventually(fn -> Session.dump(second) =~ ~r/^to-both$/m end)

      # The "connection" in the second tab drops: cat ends, bash is back.
      Session.write(second, <<4>>)
      assert eventually(fn -> match?({_, "bash"}, Pty.foreground(second)) end)

      # The next keystroke goes nowhere, not even to the tab it was typed in.
      assert {:paused, [^second]} = Tabs.send_input(first, "nowhere\r")
      Process.sleep(200)
      refute Session.dump(first) =~ "nowhere"
      refute Session.dump(second) =~ "nowhere"
      assert MapSet.member?(:sys.get_state(Tabs).lost, second)

      # Taking the lost tab out lets the rest go on.
      {:ok, :left} = Tabs.toggle_broadcast(second, ["cat"])
      assert :sent = Tabs.send_input(first, "again\r")
      assert eventually(fn -> Session.dump(first) =~ ~r/^again$/m end)
    end

    test "a local tab joins only when asked, and isn't checked" do
      [first] = ids()
      {:ok, second} = Tabs.new_tab()
      run_cat(second)
      {:ok, :joined} = Tabs.toggle_broadcast(first, ["cat"], local: true)
      {:ok, :joined} = Tabs.toggle_broadcast(second, ["cat"])

      # Running something in the local tab changes its foreground: fine.
      Session.write(first, "sleep 2\r")
      assert eventually(fn -> match?({_, "sleep"}, Pty.foreground(first)) end)
      assert :sent = Tabs.send_input(second, "both\r")
      assert MapSet.size(:sys.get_state(Tabs).lost) == 0
    end

    test "the check runs by itself and marks a lost tab before anyone types" do
      Tabs.attach_window(self())
      [first] = ids()
      {:ok, second} = Tabs.new_tab()
      run_cat(first)
      run_cat(second)
      {:ok, :joined} = Tabs.toggle_broadcast(first, ["cat"])
      {:ok, :joined} = Tabs.toggle_broadcast(second, ["cat"])

      Session.write(first, <<4>>)
      assert eventually(fn -> MapSet.member?(:sys.get_state(Tabs).lost, first) end)
    end
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

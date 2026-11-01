defmodule Guiltty.TabsTest do
  # Guiltty.Tabs and Guiltty.Sessions have global names: not async.
  use ExUnit.Case, async: false

  alias Guiltty.{Session, Tabs}
  alias Guiltty.Session.{Pty, Screen}

  @tabs :test_tabs

  setup do
    start_supervised!({DynamicSupervisor, name: Guiltty.Sessions, strategy: :one_for_one})

    session_opts = [
      shell: System.find_executable("bash"),
      args: ["--norc", "--noprofile"],
      env: %{"PS1" => "$ "}
    ]

    tabs = start_supervised!({Tabs, name: @tabs, session_opts: session_opts})
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

  defp ids, do: Tabs.list(@tabs) |> elem(0) |> Enum.map(&elem(&1, 0))

  test "starts with one tab" do
    assert [id] = ids()
    assert Tabs.active(@tabs) == id
  end

  test "new tabs open after the active one and become active" do
    [first] = ids()
    {:ok, second} = Tabs.new_tab(@tabs)
    {:ok, third} = Tabs.new_tab(@tabs)
    assert ids() == [first, second, third]
    assert Tabs.active(@tabs) == third

    :ok = Tabs.switch(@tabs, 0)
    {:ok, fourth} = Tabs.new_tab(@tabs)
    assert ids() == [first, fourth, second, third]
  end

  test "switching wraps around" do
    [first] = ids()
    {:ok, second} = Tabs.new_tab(@tabs)
    :ok = Tabs.switch(@tabs, :next)
    assert Tabs.active(@tabs) == first
    :ok = Tabs.switch(@tabs, :prev)
    assert Tabs.active(@tabs) == second
    :ok = Tabs.switch(@tabs, 7)
    assert Tabs.active(@tabs) == second
  end

  test "a tab ends when its shell exits; the one to its right takes over" do
    [first] = ids()
    {:ok, second} = Tabs.new_tab(@tabs)
    {:ok, third} = Tabs.new_tab(@tabs)
    :ok = Tabs.switch(@tabs, 1)
    Session.write(second, "exit\r")
    assert eventually(fn -> ids() == [first, third] end)
    assert Tabs.active(@tabs) == third
  end

  test "titles come from the program" do
    [id] = ids()
    Session.write(id, "printf '\\e]2;my title\\a'\r")
    assert eventually(fn -> Tabs.list(@tabs) == {[{id, "my title"}], id} end)
  end

  test "windows hear about every change" do
    %{list: tabs, active: active, locked: locked} = Tabs.attach_window(@tabs, self())
    assert [{^active, _}] = tabs
    assert MapSet.size(locked) == 0
    {:ok, second} = Tabs.new_tab(@tabs)
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
    {:ok, second} = Tabs.new_tab(@tabs)
    Process.exit(tabs, :kill)
    assert eventually(fn -> Process.whereis(@tabs) not in [nil, tabs] end)
    assert ids() == [first, second]
    {:ok, third} = Tabs.new_tab(@tabs)
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
    {:ok, second} = Tabs.new_tab(@tabs)
    Session.write(second, "pwd\r")
    assert eventually(fn -> Session.dump(second) =~ ~r/^\/usr\/share$/m end)
  end

  test "closing the unlocked tabs keeps the locked ones" do
    Tabs.attach_window(@tabs, self())
    [first] = ids()
    {:ok, second} = Tabs.new_tab(@tabs)
    {:ok, third} = Tabs.new_tab(@tabs)

    :ok = Tabs.toggle_lock(@tabs, second)
    assert MapSet.equal?(:sys.get_state(@tabs).locked, MapSet.new([second]))

    :ok = Tabs.close_unlocked(@tabs)
    assert eventually(fn -> ids() == [second] end)
    refute first in ids() or third in ids()

    # Unlocking works too.
    :ok = Tabs.toggle_lock(@tabs, second)
    assert MapSet.size(:sys.get_state(@tabs).locked) == 0
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

      assert Tabs.ssh_host(~w(ssh -A -i ~/.ssh/id -o StrictHostKeyChecking=no db.lan)) ==
               "db.lan"

      assert Tabs.ssh_host(~w(ssh)) == nil
    end

    test "only tabs running an allowed program can join" do
      [first] = ids()
      assert eventually(fn -> match?({_, "bash"}, Pty.foreground(first)) end)
      assert {:error, {:not_allowed, "bash"}} = Tabs.toggle_broadcast(@tabs, first, ["cat"])
      run_cat(first)
      assert {:ok, :joined} = Tabs.toggle_broadcast(@tabs, first, ["cat"])
      assert {:ok, :left} = Tabs.toggle_broadcast(@tabs, first, ["cat"])
    end

    test "typing in one goes to all; a lost one pauses it, leaving resumes it" do
      Tabs.attach_window(@tabs, self())
      [first] = ids()
      {:ok, second} = Tabs.new_tab(@tabs)
      run_cat(first)
      run_cat(second)
      {:ok, :joined} = Tabs.toggle_broadcast(@tabs, first, ["cat"])
      {:ok, :joined} = Tabs.toggle_broadcast(@tabs, second, ["cat"])

      assert :sent = Tabs.send_input(@tabs, first, "to-both\r")
      assert eventually(fn -> Session.dump(first) =~ ~r/^to-both$/m end)
      assert eventually(fn -> Session.dump(second) =~ ~r/^to-both$/m end)

      # The "connection" in the second tab drops: cat ends, bash is back.
      Session.write(second, <<4>>)
      assert eventually(fn -> match?({_, "bash"}, Pty.foreground(second)) end)

      # The next keystroke goes nowhere, not even to the tab it was typed in.
      assert {:paused, [^second]} = Tabs.send_input(@tabs, first, "nowhere\r")
      Process.sleep(200)
      refute Session.dump(first) =~ "nowhere"
      refute Session.dump(second) =~ "nowhere"
      assert MapSet.member?(:sys.get_state(@tabs).lost, second)

      # Taking the lost tab out lets the rest go on.
      {:ok, :left} = Tabs.toggle_broadcast(@tabs, second, ["cat"])
      assert :sent = Tabs.send_input(@tabs, first, "again\r")
      assert eventually(fn -> Session.dump(first) =~ ~r/^again$/m end)
    end

    test "a local tab joins only when asked, and isn't checked" do
      [first] = ids()
      {:ok, second} = Tabs.new_tab(@tabs)
      run_cat(second)
      {:ok, :joined} = Tabs.toggle_broadcast(@tabs, first, ["cat"], local: true)
      {:ok, :joined} = Tabs.toggle_broadcast(@tabs, second, ["cat"])

      # Running something in the local tab changes its foreground: fine.
      Session.write(first, "sleep 2\r")
      assert eventually(fn -> match?({_, "sleep"}, Pty.foreground(first)) end)
      assert :sent = Tabs.send_input(@tabs, second, "both\r")
      assert MapSet.size(:sys.get_state(@tabs).lost) == 0
    end

    test "the check runs by itself and marks a lost tab before anyone types" do
      Tabs.attach_window(@tabs, self())
      [first] = ids()
      {:ok, second} = Tabs.new_tab(@tabs)
      run_cat(first)
      run_cat(second)
      {:ok, :joined} = Tabs.toggle_broadcast(@tabs, first, ["cat"])
      {:ok, :joined} = Tabs.toggle_broadcast(@tabs, second, ["cat"])

      Session.write(first, <<4>>)
      assert eventually(fn -> MapSet.member?(:sys.get_state(@tabs).lost, first) end)
    end
  end

  test "resize applies to every tab and to new ones" do
    [first] = ids()
    {:ok, second} = Tabs.new_tab(@tabs)
    :ok = Tabs.resize(@tabs, 100, 30)
    assert Session.size(first) == {100, 30}
    assert Session.size(second) == {100, 30}
    {:ok, third} = Tabs.new_tab(@tabs)
    assert Session.size(third) == {100, 30}
  end

  test "the active tab moves left and right, never past either end" do
    [first] = ids()
    {:ok, second} = Tabs.new_tab(@tabs)
    {:ok, third} = Tabs.new_tab(@tabs)

    :ok = Tabs.move(@tabs, :right)
    assert ids() == [first, second, third]

    :ok = Tabs.move(@tabs, :left)
    assert ids() == [first, third, second]
    :ok = Tabs.move(@tabs, :left)
    :ok = Tabs.move(@tabs, :left)
    assert ids() == [third, first, second]
    assert Tabs.active(@tabs) == third
  end

  test "a name shows instead of the title; an empty one gives the title back" do
    [id] = ids()
    Session.write(id, "printf '\\e]2;from bash\\a'\r")
    assert eventually(fn -> Tabs.list(@tabs) == {[{id, "from bash"}], id} end)

    :ok = Tabs.rename(@tabs, id, "prod db")
    assert Tabs.list(@tabs) == {[{id, "prod db"}], id}

    # The program can't take the name away.
    Session.write(id, "printf '\\e]2;again\\a'\r")
    assert eventually(fn -> :sys.get_state(@tabs).titles[id] == "again" end)
    assert Tabs.list(@tabs) == {[{id, "prod db"}], id}

    :ok = Tabs.rename(@tabs, id, "")
    assert Tabs.list(@tabs) == {[{id, "again"}], id}
  end

  defp marks, do: :sys.get_state(@tabs).marks

  # What a window does when you look at a tab and then go back to the
  # first: switching clears the tab's mark in Tabs, viewing its Screen
  # resets what the Screen told Tabs. After its first prompt, which is
  # output too.
  defp look_at(id, index) do
    assert eventually(fn -> Session.dump(id) =~ ~r/^\$/m end)
    :ok = Tabs.switch(@tabs, index)
    :ok = Screen.subscribe(id, self())
    :ok = Screen.unsubscribe(id, self())
    :ok = Tabs.switch(@tabs, 0)
  end

  test "a tab you're not looking at is marked for output, then for the bell" do
    [first] = ids()
    {:ok, second} = Tabs.new_tab(@tabs)
    look_at(second, 1)

    Session.write(second, "echo hi\r")
    assert eventually(fn -> marks() == %{second => :activity} end)

    Session.write(second, "printf '\\a'\r")
    assert eventually(fn -> marks() == %{second => :bell} end)

    # The active tab is never marked; switching to a tab clears its mark.
    Session.write(first, "printf '\\a'\r")
    :ok = Tabs.switch(@tabs, 1)
    assert marks() == %{}
  end

  test "output right after a resize isn't activity: shells redraw their prompt" do
    {:ok, second} = Tabs.new_tab(@tabs)
    look_at(second, 1)
    :ok = Tabs.resize(@tabs, 90, 30)

    Session.write(second, "echo during\r")
    assert eventually(fn -> Session.dump(second) =~ ~r/^during$/m end)
    assert marks() == %{}

    Process.sleep(1_100)
    Session.write(second, "echo after\r")
    assert eventually(fn -> marks() == %{second => :activity} end)
  end
end

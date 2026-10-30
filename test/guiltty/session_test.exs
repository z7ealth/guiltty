defmodule Guiltty.SessionTest do
  use ExUnit.Case, async: true

  alias Guiltty.Session

  setup context do
    id = context.test

    opts = [
      id: id,
      shell: System.find_executable("bash"),
      args: ["--norc", "--noprofile"],
      env: %{"PS1" => "$ ", "HISTFILE" => "/dev/null"}
    ]

    pid = start_supervised!({Session.Supervisor, opts})
    %{id: id, sup: pid}
  end

  defp eventually(fun, tries \\ 250) do
    if fun.() or tries == 0, do: fun.(), else: Process.sleep(20) && eventually(fun, tries - 1)
  end

  test "a command's output reaches the screen", %{id: id} do
    assert eventually(fn -> Session.dump(id) =~ ~r/^\$/m end)
    Session.write(id, "echo $((6 * 7))\r")
    assert eventually(fn -> Session.dump(id) =~ ~r/^42$/m end)
    assert Session.dump(id) =~ "$ echo $((6 * 7))"
  end

  test "TERM is xterm-256color with truecolor", %{id: id} do
    Session.write(id, "echo $TERM $COLORTERM\r")
    assert eventually(fn -> Session.dump(id) =~ ~r/^xterm-256color truecolor$/m end)
  end

  test "resizing reaches the grid and the kernel", %{id: id} do
    assert eventually(fn -> Session.dump(id) =~ ~r/^\$/m end)
    :ok = Session.resize(id, 100, 30)
    Session.write(id, "tput cols; tput lines\r")
    assert eventually(fn -> Session.dump(id) =~ ~r/^100\n30$/m end)
    assert Session.dump(id) |> String.split("\n") |> length() == 30
  end

  test "Ctrl+C interrupts the foreground job", %{id: id} do
    Session.write(id, "sleep 100\r")
    Process.sleep(200)
    Session.write(id, <<3>>)
    Session.write(id, "echo back\r")
    assert eventually(fn -> Session.dump(id) =~ ~r/^back$/m end)
  end

  test "a parser crash keeps the screen", %{id: id} do
    Session.write(id, "echo before\r")
    assert eventually(fn -> Session.dump(id) =~ ~r/^before$/m end)

    parser = GenServer.whereis(Session.via(id, :parser))
    Process.exit(parser, :kill)
    assert eventually(fn -> GenServer.whereis(Session.via(id, :parser)) not in [nil, parser] end)

    Session.write(id, "echo after\r")
    assert eventually(fn -> Session.dump(id) =~ ~r/^after$/m end)
    assert Session.dump(id) =~ ~r/^before$/m
  end

  test "killing the session supervisor brings back a working session", %{id: id, sup: sup} do
    old_pty = GenServer.whereis(Session.via(id, :pty))
    Process.exit(sup, :kill)

    # The old Pty still exits cleanly, and the new one can take its name.
    assert eventually(fn ->
             pty = GenServer.whereis(Session.via(id, :pty))
             pty != nil and pty != old_pty
           end)

    Session.write(id, "echo reborn\r")
    assert eventually(fn -> Session.dump(id) =~ ~r/^reborn$/m end)
  end

  test "exit ends the session", %{id: id, sup: sup} do
    ref = Process.monitor(sup)
    Session.write(id, "exit\r")
    assert_receive {:DOWN, ^ref, :process, ^sup, :shutdown}, 5000
  end
end

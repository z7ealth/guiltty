defmodule Guiltty.SessionTest do
  use ExUnit.Case, async: true

  alias Guiltty.Session

  setup context do
    id = context.test

    opts = [
      id: id,
      args: ["--norc", "--noprofile"],
      env: %{"PS1" => "$ ", "HISTFILE" => "/dev/null"}
    ]

    pid = start_supervised!({Session.Supervisor, opts})
    %{id: id, sup: pid}
  end

  defp eventually(fun, tries \\ 100) do
    if fun.() or tries == 0, do: fun.(), else: Process.sleep(20) && eventually(fun, tries - 1)
  end

  test "a command's output reaches the screen", %{id: id} do
    assert eventually(fn -> Session.dump(id) =~ ~r/^\$/m end)
    Session.write(id, "echo $((6 * 7))\r")
    assert eventually(fn -> Session.dump(id) =~ ~r/^42$/m end)
    assert Session.dump(id) =~ "$ echo $((6 * 7))"
  end

  test "TERM is dumb", %{id: id} do
    Session.write(id, "echo $TERM\r")
    assert eventually(fn -> Session.dump(id) =~ ~r/^dumb$/m end)
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

  test "exit ends the session", %{id: id, sup: sup} do
    ref = Process.monitor(sup)
    Session.write(id, "exit\r")
    assert_receive {:DOWN, ^ref, :process, ^sup, :shutdown}, 3000
  end
end

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

  test "a flood of output never piles up in the parser's mailbox", %{id: id} do
    assert eventually(fn -> Session.dump(id) =~ ~r/^\$/m end)
    parser = GenServer.whereis(Session.via(id, :parser))
    Session.write(id, "seq 1 400000; echo FLOOD-DONE\r")

    # Sample the parser's queue while the flood runs. The Pty sends at most
    # 4 chunks before waiting for an acknowledgement; the rest of the output
    # waits in the kernel.
    samples =
      Stream.repeatedly(fn ->
        Process.sleep(5)
        {:message_queue_len, n} = Process.info(parser, :message_queue_len)
        {n, Session.dump(id) =~ "FLOOD-DONE"}
      end)
      |> Enum.reduce_while([], fn {n, done}, acc ->
        if done, do: {:halt, acc}, else: {:cont, [n | acc]}
      end)

    assert length(samples) > 10
    assert Enum.max(samples) <= 4
  end

  test "exit ends the session", %{id: id, sup: sup} do
    ref = Process.monitor(sup)
    Session.write(id, "exit\r")
    assert_receive {:DOWN, ^ref, :process, ^sup, :shutdown}, 5000
  end

  test "answers a program never reads can't pile up" do
    # In raw mode the kernel stops taking input once its buffer is full,
    # so guiltty's answers to 300,000 queries would wait in the Pty: about
    # 2.7 MB, and more for every query. Past 64 KB they're dropped.
    script = """
    stty raw -echo
    i=0; while [ $i -lt 300 ]; do printf '\\033[c%.0s' $(seq 1000); i=$((i+1)); done
    sleep 30
    """

    start_supervised!(
      {Session.Supervisor, id: :answer_flood, shell: "/bin/sh", args: ["-c", script]},
      id: :answer_flood
    )

    pty = GenServer.whereis(Session.via(:answer_flood, :pty))

    pending = fn -> byte_size(:sys.get_state(pty).pending) end

    # Wait until the flood is over: the backlog stops changing.
    Enum.reduce_while(1..100, -1, fn _, last ->
      Process.sleep(100)
      now = pending.()
      if now == last and now > 0, do: {:halt, now}, else: {:cont, now}
    end)

    assert pending.() <= 64 * 1024
  end
end

defmodule Guiltty.Session.PtyNifSafetyTest do
  # The PTY NIF runs inside the BEAM: if it crashed, every tab would go
  # with it. These tests throw at it what it should never get, and check
  # it answers with an error, not a crash. Not async: the fd-leak test
  # counts the BEAM's open files, so no other test may open PTYs meanwhile.
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Guiltty.Session.PtyNif

  # Valid, harmless arguments for open/6: a program that doesn't exist,
  # so a child that does start just exits 127.
  @open_args ["/nonexistent/guiltty-test", ["x"], [], 80, 24, ""]

  defp wait_gone(pty, tries \\ 300) do
    case PtyNif.wait(pty) do
      :running when tries > 0 -> Process.sleep(10) && wait_gone(pty, tries - 1)
      status -> status
    end
  end

  defp drain(pty) do
    case PtyNif.read(pty) do
      {:ok, _} -> drain(pty)
      _ -> :ok
    end
  end

  # Whatever open returned, leave nothing behind.
  defp cleanup({:ok, pty, _os_pid}) do
    PtyNif.close(pty)
    PtyNif.kill(pty, 9)
    wait_gone(pty)
  end

  defp cleanup(_), do: :ok

  defp junk, do: StreamData.term()

  property "open with a junk argument raises or returns, never crashes" do
    check all(position <- StreamData.integer(0..5), value <- junk(), max_runs: 300) do
      args = List.replace_at(@open_args, position, value)

      result =
        try do
          apply(PtyNif, :open, args)
        rescue
          ArgumentError -> :badarg
        end

      assert result == :badarg or match?({:ok, _, _}, result) or match?({:error, _}, result)
      cleanup(result)
    end
  end

  property "every call on something that isn't a pty is a badarg" do
    calls = [
      &PtyNif.read/1,
      &PtyNif.select_read/1,
      &PtyNif.select_write/1,
      &PtyNif.winch/1,
      &PtyNif.foreground/1,
      &PtyNif.close/1,
      &PtyNif.wait/1,
      &PtyNif.write(&1, "x"),
      &PtyNif.resize(&1, 80, 24),
      &PtyNif.kill(&1, 15)
    ]

    check all(value <- junk(), call <- StreamData.member_of(calls), max_runs: 500) do
      assert_raise ArgumentError, fn -> call.(value) end
    end
  end

  property "junk sizes, signals and data on a real pty are refused or handled" do
    {:ok, pty, _} = PtyNif.open("/bin/cat", ["cat"], [], 80, 24, "")

    check all(a <- junk(), b <- junk(), max_runs: 300) do
      for call <- [
            fn -> PtyNif.resize(pty, a, b) end,
            fn -> PtyNif.write(pty, a) end,
            # Never a signal by mistake: only 1..64 reach the child.
            fn -> if a in [9, 19, 17, 18], do: :skip, else: PtyNif.kill(pty, a) end
          ] do
        try do
          call.()
        rescue
          ArgumentError -> :ok
        end
      end
    end

    drain(pty)
    PtyNif.close(pty)
    PtyNif.kill(pty, 9)
    wait_gone(pty)
  end

  test "signal numbers outside 1..64 are refused" do
    {:ok, pty, _} = PtyNif.open("/bin/cat", ["cat"], [], 80, 24, "")

    for sig <- [0, -1, -9, 65, 1000, 2 ** 40],
        do: assert_raise(ArgumentError, fn -> PtyNif.kill(pty, sig) end)

    assert PtyNif.wait(pty) == :running
    cleanup({:ok, pty, 0})
  end

  test "a closed pty answers every call, and closes twice" do
    {:ok, pty, _} = PtyNif.open("/bin/cat", ["cat"], [], 80, 24, "")
    assert PtyNif.close(pty) == :ok
    assert PtyNif.close(pty) == :ok
    assert PtyNif.read(pty) == :eof
    assert PtyNif.write(pty, "x") == {:error, :ebadf}
    assert PtyNif.select_read(pty) == {:error, :ebadf}
    assert PtyNif.select_write(pty) == {:error, :ebadf}
    assert PtyNif.resize(pty, 80, 24) == {:error, :ebadf}
    assert PtyNif.winch(pty) == {:error, :ebadf}
    assert PtyNif.foreground(pty) == {:error, :ebadf}
    # Closing the master hung up cat: it ends by itself.
    assert wait_gone(pty) in [:gone, {:signaled, 1}, {:exited, 0}]
  end

  test "once the child is gone, signals can't reach anyone" do
    {:ok, pty, os_pid} = PtyNif.open("/bin/true", ["true"], [], 80, 24, "")
    drain(pty)
    assert wait_gone(pty) in [:gone, {:exited, 0}]
    assert PtyNif.wait(pty) == :gone
    # The pidfd is gone too: ESRCH, even if os_pid now belonged to someone.
    assert PtyNif.kill(pty, 15) == {:error, :esrch}
    refute File.exists?("/proc/#{os_pid}"), "the shell is a zombie"
    PtyNif.close(pty)
  end

  test "opening and closing many ptys leaks no file descriptors" do
    count = fn -> length(File.ls!("/proc/self/fd")) end
    before = count.()

    for _ <- 1..50 do
      {:ok, pty, _} = PtyNif.open("/bin/true", ["true"], [], 80, 24, "")
      drain(pty)
      PtyNif.close(pty)
      wait_gone(pty)
    end

    # A pty dropped without close or wait: its destructor cleans up.
    {:ok, _pty, _} = PtyNif.open("/bin/cat", ["cat"], [], 80, 24, "")
    :erlang.garbage_collect()
    Process.sleep(50)

    assert count.() == before
  end

  test "many processes calling one pty at once don't crash the BEAM" do
    {:ok, pty, _} = PtyNif.open("/bin/cat", ["cat"], [], 80, 24, "")

    calls = [
      fn -> PtyNif.read(pty) end,
      fn -> PtyNif.write(pty, "hello\r") end,
      fn -> PtyNif.resize(pty, Enum.random(1..300), Enum.random(1..100)) end,
      fn -> PtyNif.foreground(pty) end,
      fn -> PtyNif.winch(pty) end,
      fn -> PtyNif.wait(pty) end,
      fn -> PtyNif.select_read(pty) end
    ]

    tasks =
      for i <- 1..16 do
        Task.async(fn ->
          for n <- 1..300 do
            # One task closes it halfway, while the others keep going.
            if i == 1 and n == 150, do: PtyNif.close(pty), else: Enum.random(calls).()
          end

          :ok
        end)
      end

    assert Enum.all?(Task.await_many(tasks, 30_000), &(&1 == :ok))
    PtyNif.kill(pty, 9)
    assert wait_gone(pty) in [:gone, {:signaled, 9}, {:signaled, 1}]
  end
end

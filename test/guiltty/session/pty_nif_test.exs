defmodule Guiltty.Session.PtyNifTest do
  use ExUnit.Case, async: true

  alias Guiltty.Session.PtyNif

  defp read_all(pty, acc \\ "") do
    case PtyNif.read(pty) do
      {:ok, bytes} ->
        read_all(pty, acc <> bytes)

      :eagain ->
        :ok = PtyNif.select_read(pty)
        assert_receive {:select, ^pty, :undefined, :ready_input}, 5000
        read_all(pty, acc)

      :eof ->
        acc
    end
  end

  defp wait_gone(pty) do
    case PtyNif.wait(pty) do
      :running -> Process.sleep(10) && wait_gone(pty)
      status -> status
    end
  end

  test "runs a program on the slave and reads its output until EIO" do
    {:ok, pty, os_pid} = PtyNif.open("/bin/echo", ["echo", "hello"], [], 80, 24, "")
    assert os_pid > 0
    # ONLCR in the line discipline turns echo's \n into \r\n.
    assert read_all(pty) == "hello\r\n"
    assert wait_gone(pty) in [:gone, {:exited, 0}]
    assert PtyNif.close(pty) == :ok
  end

  test "the child gets a controlling terminal of the requested size" do
    {:ok, pty, _} = PtyNif.open("/bin/sh", ["sh", "-c", "stty size; tty"], [], 100, 30, "")
    assert "30 100\r\n/dev/pts/" <> _ = read_all(pty)
  end

  test "writes reach the child through the line discipline" do
    {:ok, pty, _} = PtyNif.open("/bin/sh", ["sh", "-c", "read x; echo got:$x"], [], 80, 24, "")
    assert {:ok, 4} = PtyNif.write(pty, "abc\r")
    output = read_all(pty)
    # First the echo of what we typed, then the program's output.
    assert output == "abc\r\ngot:abc\r\n"
  end

  test "the child starts with default signal handling" do
    # The BEAM ignores SIGCHLD and others; that must not leak into the shell.
    {:ok, pty, _} =
      PtyNif.open("/bin/sh", ["sh", "-c", "grep SigIgn /proc/self/status"], [], 80, 24, "")

    assert read_all(pty) =~ ~r/SigIgn:\s+0+\r\n/
  end

  test "bad arguments raise" do
    assert_raise ArgumentError, fn -> PtyNif.open("/bin/echo", ["a\0b"], [], 80, 24, "") end
    assert_raise ArgumentError, fn -> PtyNif.open("/bin/echo", ["echo"], [], 0, 24, "") end
    assert_raise ArgumentError, fn -> PtyNif.open("/bin/pwd", ["pwd"], [], 80, 24, "/t\0mp") end
  end

  test "foreground tells which process group the terminal is running" do
    {:ok, pty, os_pid} = PtyNif.open("/bin/sh", ["sh", "-c", "sleep 2"], [], 80, 24, "")
    # sh is the session leader and its group is in the foreground, once it
    # has claimed the terminal (until then the kernel answers EIO).
    assert Enum.any?(1..100, fn _ ->
             PtyNif.foreground(pty) == {:ok, os_pid} or (Process.sleep(10) && false)
           end)
  end

  test "the child starts in the directory it's given" do
    {:ok, pty, _} = PtyNif.open("/bin/pwd", ["pwd"], [], 80, 24, "/usr/share")
    assert read_all(pty) =~ "/usr/share\r\n"
  end
end

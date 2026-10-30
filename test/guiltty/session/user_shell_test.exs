defmodule Guiltty.Session.UserShellTest do
  # Changes $SHELL, which is global to the VM: not async.
  use ExUnit.Case, async: false

  alias Guiltty.Session.Pty

  setup do
    original = System.get_env("SHELL")

    on_exit(fn ->
      if original, do: System.put_env("SHELL", original), else: System.delete_env("SHELL")
    end)
  end

  test "uses $SHELL when it's an executable" do
    System.put_env("SHELL", "/bin/sh")
    assert Pty.user_shell() == "/bin/sh"
  end

  test "falls back when $SHELL is missing or not executable" do
    for bad <- ["/nonexistent/shell", "/etc/passwd", ""] do
      System.put_env("SHELL", bad)
      shell = Pty.user_shell()
      assert shell != bad
      assert File.exists?(shell)
    end

    System.delete_env("SHELL")
    assert File.exists?(Pty.user_shell())
  end
end

defmodule Guiltty.ExecTest do
  use ExUnit.Case, async: true

  alias Guiltty.Exec

  @moduletag :tmp_dir

  test "finds programs by name or path, in the PATH a shell gets" do
    assert Exec.find("sh") =~ ~r{/sh$}
    assert Exec.find("/bin/sh") == "/bin/sh"
    assert Exec.find("no-such-program-here") == nil
  end

  test "a background program runs where it's told, with the environment it's given",
       %{tmp_dir: dir} do
    env = ["PATH=/usr/bin:/bin", "GUILTTY_TEST=hello"]
    script = ~S(printf '%s %s' "$PWD" "$GUILTTY_TEST" > out)
    {:ok, _} = Exec.background("/bin/sh", ["-c", script], cd: dir, env: env, notify: self())

    out = Path.join(dir, "out")
    assert eventually(fn -> File.read(out) == {:ok, "#{dir} hello"} end)
    # It succeeded: nothing to say.
    refute_receive {:exec_failed, _}, 200
  end

  test "the VM's own variables don't reach it", %{tmp_dir: dir} do
    System.put_env("GUILTTY_EXEC_TEST_VM_ONLY", "leak")
    script = ~S(printf '[%s]' "$GUILTTY_EXEC_TEST_VM_ONLY" > out)
    {:ok, _} = Exec.background("/bin/sh", ["-c", script], cd: dir, env: ["A=b"])
    assert eventually(fn -> File.read(Path.join(dir, "out")) == {:ok, "[]"} end)
  after
    System.delete_env("GUILTTY_EXEC_TEST_VM_ONLY")
  end

  test "a failure says so, with the last line it printed" do
    script = "echo starting; echo 'no screen to grab' >&2; exit 3"
    {:ok, _} = Exec.background("/bin/sh", ["-c", script], env: ["A=b"], notify: self())
    assert_receive {:exec_failed, "sh failed (exit 3): no screen to grab"}, 2_000
  end

  test "a folder that's gone: it starts in your home instead", %{tmp_dir: dir} do
    script = ~S(printf '%s' "$PWD" > "$OUT")
    gone = Path.join(dir, "gone")
    env = ["OUT=#{Path.join(dir, "out")}"]
    {:ok, _} = Exec.background("/bin/sh", ["-c", script], cd: gone, env: env, notify: self())
    assert eventually(fn -> File.read(Path.join(dir, "out")) == {:ok, System.user_home!()} end)
    refute_receive {:exec_failed, _}, 200
  end

  test "a program that can't start says so", %{tmp_dir: dir} do
    plain = Path.join(dir, "not-executable")
    File.write!(plain, "")
    {:ok, _} = Exec.background(plain, [], env: ["A=b"], notify: self())
    assert_receive {:exec_failed, "couldn't start not-executable: :eacces"}, 2_000
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end
end

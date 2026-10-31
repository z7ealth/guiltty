defmodule Guiltty.Session.EnvironmentTest do
  # Sets variables in the VM's environment, which is global: not async.
  use ExUnit.Case, async: false

  alias Guiltty.Session

  # What the release start script and the Erlang runtime would set.
  @vm_vars %{
    "RELEASE_NODE" => "guiltty",
    "RELEASE_NAME" => "guiltty",
    "RELEASE_COOKIE" => "secret-cookie",
    "BINDIR" => "/opt/erts/bin",
    "ROOTDIR" => "/opt/guiltty",
    "EMU" => "beam",
    "PROGNAME" => "erl",
    "GUILTTY_NODE" => "guiltty@127.0.0.1",
    "ERL_EPMD_ADDRESS" => "127.0.0.1"
  }

  setup context do
    for {name, value} <- @vm_vars, do: System.put_env(name, value)
    System.put_env("GUILTTY_TEST_KEEP", "kept")

    on_exit(fn ->
      for name <- Map.keys(@vm_vars), do: System.delete_env(name)
      System.delete_env("GUILTTY_TEST_KEEP")
    end)

    id = context.test

    start_supervised!(
      {Session.Supervisor,
       id: id,
       shell: System.find_executable("bash"),
       args: ["--norc", "--noprofile"],
       env: %{"PS1" => "$ "}}
    )

    %{id: id}
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

  test "the shell doesn't inherit the VM's own variables", %{id: id} do
    Session.write(
      id,
      "env | grep -cE '^(RELEASE_|BINDIR=|ROOTDIR=|EMU=|PROGNAME=|GUILTTY_NODE=|ERL_EPMD_ADDRESS=)'; echo done\r"
    )

    assert eventually(fn -> Session.dump(id) =~ ~r/^0\ndone$/m end)
    refute Session.dump(id) =~ "secret-cookie"
  end

  test "the rest of the environment is passed on", %{id: id} do
    Session.write(id, "echo $GUILTTY_TEST_KEEP\r")
    assert eventually(fn -> Session.dump(id) =~ ~r/^kept$/m end)
  end
end

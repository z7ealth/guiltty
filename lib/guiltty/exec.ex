defmodule Guiltty.Exec do
  @moduledoc """
  The programs the `exec` setting binds to keys (book chapter 16, "Your
  own keys"). The Window opens most of them in a pane, a tab or a
  window, as it does a shell. This module has the two parts that aren't
  a pane:

    * `find/1` looks a program up in the `PATH` a tab's shell gets, not
      the VM's: the release puts its own `bin` first, where `guiltty` is
      the release's start script, not the command you installed.
    * `background/3` runs one with no terminal at all, for a screenshot
      tool, a script, a notification.

  A background program runs through an Erlang port, watched by a small
  process under `Guiltty.Background` (a `Task.Supervisor`). The port
  gives it pipes instead of a terminal: its output is read and thrown
  away, except the end of it, which is the notice you see if it fails.
  """

  alias Guiltty.Session.Pty

  # What's kept of a background program's output, for its error notice.
  @tail_bytes 512
  # How much of the last line the notice shows.
  @notice_chars 80

  @doc """
  The full path of `program` (a name, or a path with a `/`), searched in
  the `PATH` a shell started by guiltty gets; nil if there's no such
  executable.
  """
  def find(program) do
    path = Pty.shell_path(System.get_env("PATH", ""))

    case :os.find_executable(String.to_charlist(program), String.to_charlist(path)) do
      false -> nil
      found -> List.to_string(found)
    end
  end

  @doc """
  Runs `path` with `args`, with no terminal, and returns at once. Options:
  `:cd` (where it starts; your home folder if that's nil or gone), `:env` (its whole
  environment, as `"NAME=value"` strings, like `Pty.child_env/2` gives)
  and `:notify` (a pid). If it exits with an error, or can't start,
  `notify` gets `{:exec_failed, message}`.
  """
  def background(path, args, opts) do
    Task.Supervisor.start_child(Guiltty.Background, fn -> run(path, args, opts) end)
  end

  defp run(path, args, opts) do
    name = Path.basename(path)

    # A folder that's gone wouldn't raise: the port's helper would print to
    # guiltty's stderr and exit 2. Home is a better place to start.
    cd =
      if is_binary(opts[:cd]) and File.dir?(opts[:cd]), do: opts[:cd], else: System.user_home!()

    port_opts = [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: args,
      cd: cd,
      env: port_env(opts[:env])
    ]

    try do
      Port.open({:spawn_executable, path}, port_opts)
    rescue
      # The file went away, or isn't executable any more.
      e in ErlangError -> notify(opts, "couldn't start #{name}: #{inspect(e.original)}")
    else
      port -> wait(port, name, "", opts)
    end
  end

  defp wait(port, name, tail, opts) do
    receive do
      {^port, {:data, data}} ->
        wait(port, name, keep_tail(tail <> data), opts)

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, code}} ->
        notify(opts, failure(name, code, tail))
    end
  end

  defp keep_tail(tail) when byte_size(tail) <= @tail_bytes, do: tail

  defp keep_tail(tail),
    do: binary_part(tail, byte_size(tail) - @tail_bytes, @tail_bytes)

  defp failure(name, code, tail) do
    last =
      tail
      # The cut can fall inside a character.
      |> String.replace_invalid("")
      |> String.split(["\r\n", "\n", "\r"], trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> List.last()

    case last do
      nil -> "#{name} failed (exit #{code})"
      line -> "#{name} failed (exit #{code}): #{String.slice(line, 0, @notice_chars)}"
    end
  end

  defp notify(opts, message) do
    if pid = opts[:notify], do: send(pid, {:exec_failed, message})
    :ok
  end

  # A port's :env changes the VM's environment; it doesn't replace it. So
  # every variable of the VM's that the program shouldn't have is unset
  # (false), the rest set to what a shell would get.
  defp port_env(nil), do: []

  defp port_env(env) do
    wanted =
      Map.new(env, fn pair ->
        [name, value] = String.split(pair, "=", parts: 2)
        {name, value}
      end)

    unset = for {name, _} <- System.get_env(), not is_map_key(wanted, name), do: {name, false}

    for {name, value} <- Map.to_list(wanted) ++ unset,
        do: {String.to_charlist(name), value && String.to_charlist(value)}
  end
end

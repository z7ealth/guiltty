defmodule Guiltty.Session.Pty do
  @moduledoc """
  Owns one pseudoterminal and the shell running on it: the user's own shell
  (see `user_shell/0`) unless the `:shell` option says otherwise.

  Bytes from the shell go to the attached parser. Reading only starts once a
  parser attaches, so the first prompt is never lost, and stops while there
  is none: the kernel buffers the output until a new parser shows up.

  ## Backpressure

  The parser acknowledges each chunk once the screen has it (`ack/1`). With
  `@max_in_flight` chunks unacknowledged, this process stops reading. The
  shell's output then waits in the kernel's PTY buffer, and when that's
  full the shell's own `write()` blocks: a `cat` of a huge file runs exactly
  as fast as the screen can keep up, and nothing piles up in memory.

  ## Telemetry

    * `[:guiltty, :pty, :read]` - `%{bytes: n}`, `%{session: id}`
    * `[:guiltty, :session, :parser_restarted]` - `%{}`, `%{session: id}`
  """

  use GenServer, restart: :transient

  import Bitwise

  require Logger

  alias Guiltty.Session
  alias Guiltty.Session.PtyNif

  # Chunks read per readiness message, so one chatty shell can't hog the process.
  @max_reads 16
  # Chunks sent to the parser and not yet acknowledged.
  @max_in_flight 4
  @sighup 1
  @sigkill 9

  def start_link(opts) do
    Session.start_named(opts[:id], :pty, &GenServer.start_link(__MODULE__, opts, name: &1))
  end

  @doc "Sends bytes to the shell, as if typed."
  def write(id, bytes), do: GenServer.cast(Session.via(id, :pty), {:write, bytes})

  @doc """
  Tells the kernel the terminal's new size (TIOCSWINSZ). The kernel then
  sends SIGWINCH to the foreground job, and programs like `less` redraw.
  """
  def resize(id, cols, rows), do: GenServer.call(Session.via(id, :pty), {:resize, cols, rows})

  @doc "The parser has applied one chunk to the screen."
  def ack(id), do: GenServer.cast(Session.via(id, :pty), :ack)

  @doc "Sends SIGWINCH to the foreground job, so full-screen programs redraw."
  def redraw(id), do: GenServer.cast(Session.via(id, :pty), :redraw)

  @doc """
  The shell's current directory, read from `/proc/<pid>/cwd` (the kernel
  keeps it for every process), or nil.
  """
  def cwd(id), do: GenServer.call(Session.via(id, :pty), :cwd)

  @doc "Makes `pid` the receiver of `{:pty_data, bytes}` messages."
  def attach_parser(id, pid), do: GenServer.call(Session.via(id, :pty), {:attach_parser, pid})

  @impl true
  def init(opts) do
    # So terminate/2 runs when the supervisor shuts us down.
    Process.flag(:trap_exit, true)

    shell = Keyword.get_lazy(opts, :shell, &user_shell/0)
    argv = [Path.basename(shell) | Keyword.get(opts, :args, [])]
    env = opts |> Keyword.get(:env, %{}) |> build_env()
    cols = Keyword.get(opts, :cols, 80)
    rows = Keyword.get(opts, :rows, 24)
    cwd = Keyword.get(opts, :cwd) || ""
    # Shells trust PWD when it names their directory; keep it truthful.
    env = if cwd != "", do: put_env(env, "PWD", cwd), else: env

    case PtyNif.open(shell, argv, env, cols, rows, cwd) do
      {:ok, pty, os_pid} ->
        Logger.debug("pty: started #{shell} as pid #{os_pid}")

        state = %{
          id: opts[:id],
          pty: pty,
          os_pid: os_pid,
          parser: nil,
          parsers_seen: 0,
          armed: false,
          in_flight: 0,
          pending: <<>>
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, {:open_failed, reason}}
    end
  end

  @doc """
  The shell to run: `$SHELL` if it's set, otherwise the login shell from
  the user database, otherwise bash, otherwise `/bin/sh`. Each must be an
  executable file to be picked.
  """
  def user_shell do
    Enum.find_value(
      [
        fn -> System.get_env("SHELL") end,
        &passwd_shell/0,
        fn -> System.find_executable("bash") end,
        fn -> "/bin/sh" end
      ],
      fn candidate -> if executable?(path = candidate.()), do: path end
    )
  end

  # The 7th field of the user's passwd entry. getent asks NSS (see
  # nsswitch.conf(5)), so it also finds users from LDAP or systemd-homed,
  # not just /etc/passwd.
  defp passwd_shell do
    with user when is_binary(user) <- System.get_env("USER"),
         {entry, 0} <- System.cmd("getent", ["passwd", user], stderr_to_stdout: true) do
      entry |> String.trim() |> String.split(":") |> Enum.at(6)
    else
      _ -> nil
    end
  rescue
    # getent isn't installed
    ErlangError -> nil
  end

  defp executable?(path) when is_binary(path) and path != "" do
    match?(
      {:ok, %File.Stat{type: :regular, mode: mode}} when (mode &&& 0o111) != 0,
      File.stat(path)
    )
  end

  defp executable?(_), do: false

  defp vm_variable?("RELEASE_" <> _), do: true
  defp vm_variable?(name), do: name in ~w(BINDIR ROOTDIR EMU PROGNAME)

  # The child gets our environment, saying it runs in an xterm-256color
  # terminal with 24-bit color. TERM picks the terminfo entry programs use
  # to know which escape sequences to send.
  #
  # Minus the variables that only describe this VM: the Erlang runtime's
  # (BINDIR, ROOTDIR, EMU, PROGNAME) and the release start script's
  # (RELEASE_*). A shell must not inherit them: another Mix release started
  # from it would take RELEASE_NODE as its own node name and collide with
  # ours, and RELEASE_COOKIE is the key to run code on this node.
  defp build_env(overrides) do
    System.get_env()
    |> Map.reject(fn {name, _value} -> vm_variable?(name) end)
    |> Map.drop(["TERM_PROGRAM", "TERM_PROGRAM_VERSION"])
    |> Map.merge(%{"TERM" => "xterm-256color", "COLORTERM" => "truecolor"})
    |> Map.merge(overrides)
    |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
  end

  defp put_env(env, name, value),
    do: [name <> "=" <> value | Enum.reject(env, &String.starts_with?(&1, name <> "="))]

  @impl true
  def handle_call(:cwd, _from, state) do
    case File.read_link("/proc/#{state.os_pid}/cwd") do
      {:ok, dir} -> {:reply, dir, state}
      {:error, _} -> {:reply, nil, state}
    end
  end

  def handle_call({:attach_parser, pid}, _from, state) do
    Process.monitor(pid)

    # Not the first parser: the previous one crashed. The chunks it had in
    # hand are lost, so ask full-screen programs to redraw.
    if state.parsers_seen > 0 do
      :telemetry.execute([:guiltty, :session, :parser_restarted], %{}, %{session: state.id})
      PtyNif.winch(state.pty)
    end

    state = %{state | parser: pid, parsers_seen: state.parsers_seen + 1, in_flight: 0}
    {:reply, :ok, arm(state)}
  end

  def handle_call({:resize, cols, rows}, _from, state) do
    {:reply, PtyNif.resize(state.pty, cols, rows), state}
  end

  @impl true
  def handle_cast({:write, bytes}, state) do
    {:noreply, flush(%{state | pending: state.pending <> bytes})}
  end

  def handle_cast(:ack, state) do
    {:noreply, arm(%{state | in_flight: max(state.in_flight - 1, 0)})}
  end

  def handle_cast(:redraw, state) do
    PtyNif.winch(state.pty)
    {:noreply, state}
  end

  @impl true
  def handle_info({:select, pty, _ref, :ready_input}, %{pty: pty} = state) do
    state = %{state | armed: false}

    if state.parser do
      drain(state, @max_reads)
    else
      {:noreply, state}
    end
  end

  def handle_info({:select, pty, _ref, :ready_output}, %{pty: pty} = state) do
    {:noreply, flush(state)}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{parser: pid} = state) do
    {:noreply, %{state | parser: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Closing the master hangs up the terminal, so the kernel sends SIGHUP.
    PtyNif.close(state.pty)
    # Give the shell time to exit in a separate process, so this one (and
    # its registered name) is gone right away. The helper holds the NIF
    # resource, so its destructor can't SIGKILL the shell early.
    pty = state.pty
    Task.start(fn -> reap(pty, @sighup) end)
    :ok
  end

  defp drain(state, 0), do: {:noreply, arm(state)}

  # The parser is behind: stop reading until it acknowledges something.
  defp drain(%{in_flight: n} = state, _reads_left) when n >= @max_in_flight, do: {:noreply, state}

  defp drain(state, reads_left) do
    case PtyNif.read(state.pty) do
      {:ok, bytes} ->
        :telemetry.execute([:guiltty, :pty, :read], %{bytes: byte_size(bytes)}, %{
          session: state.id
        })

        send(state.parser, {:pty_data, bytes})
        drain(%{state | in_flight: state.in_flight + 1}, reads_left - 1)

      :eagain ->
        {:noreply, arm(state)}

      :eof ->
        Logger.info("pty: shell #{state.os_pid} ended")
        {:stop, {:shutdown, :shell_exited}, state}

      {:error, reason} ->
        {:stop, {:read_failed, reason}, state}
    end
  end

  defp arm(%{armed: true} = state), do: state
  defp arm(%{parser: nil} = state), do: state
  defp arm(%{in_flight: n} = state) when n >= @max_in_flight, do: state

  defp arm(state) do
    :ok = PtyNif.select_read(state.pty)
    %{state | armed: true}
  end

  defp flush(%{pending: <<>>} = state), do: state

  defp flush(state) do
    case PtyNif.write(state.pty, state.pending) do
      {:ok, n} ->
        rest = binary_part(state.pending, n, byte_size(state.pending) - n)
        if rest != <<>>, do: PtyNif.select_write(state.pty)
        %{state | pending: rest}

      :eagain ->
        PtyNif.select_write(state.pty)
        state

      {:error, reason} ->
        Logger.warning("pty: write failed: #{inspect(reason)}")
        %{state | pending: <<>>}
    end
  end

  # Wait for the shell to exit: ask with SIGHUP first, then SIGKILL. The BEAM
  # ignores SIGCHLD, so the kernel reaps it and there's no zombie either way.
  defp reap(pty, signal) do
    with :running <- wait_for(pty, 500),
         _ <- PtyNif.kill(pty, signal),
         :running <- wait_for(pty, 500),
         _ <- PtyNif.kill(pty, @sigkill) do
      wait_for(pty, 1000)
    end
  end

  defp wait_for(pty, ms_left) do
    case PtyNif.wait(pty) do
      :running when ms_left > 0 ->
        Process.sleep(10)
        wait_for(pty, ms_left - 10)

      status ->
        status
    end
  end
end

defmodule Guiltty.Session.Pty do
  @moduledoc """
  Owns one pseudoterminal and the shell running on it.

  Bytes from the shell go to the attached parser. Reading only starts once a
  parser attaches, so the first prompt is never lost, and stops while there
  is none: the kernel buffers the output until a new parser shows up.
  """

  use GenServer, restart: :transient

  require Logger

  alias Guiltty.Session
  alias Guiltty.Session.PtyNif

  # Chunks read per readiness message, so one chatty shell can't hog the process.
  @max_reads 16
  @sighup 1
  @sigkill 9

  def start_link(opts) do
    Session.start_named(opts[:id], :pty, &GenServer.start_link(__MODULE__, opts, name: &1))
  end

  @doc "Sends bytes to the shell, as if typed."
  def write(id, bytes), do: GenServer.cast(Session.via(id, :pty), {:write, bytes})

  @doc "Makes `pid` the receiver of `{:pty_data, bytes}` messages."
  def attach_parser(id, pid), do: GenServer.call(Session.via(id, :pty), {:attach_parser, pid})

  @impl true
  def init(opts) do
    # So terminate/2 runs when the supervisor shuts us down.
    Process.flag(:trap_exit, true)

    shell = Keyword.get_lazy(opts, :shell, fn -> System.find_executable("bash") end)
    argv = [Path.basename(shell) | Keyword.get(opts, :args, [])]
    env = opts |> Keyword.get(:env, %{}) |> build_env()
    cols = Keyword.get(opts, :cols, 80)
    rows = Keyword.get(opts, :rows, 24)

    case PtyNif.open(shell, argv, env, cols, rows) do
      {:ok, pty, os_pid} ->
        Logger.debug("pty: started #{shell} as pid #{os_pid}")
        {:ok, %{pty: pty, os_pid: os_pid, parser: nil, armed: false, pending: <<>>}}

      {:error, reason} ->
        {:stop, {:open_failed, reason}}
    end
  end

  # The child gets our environment with TERM=dumb, which asks programs not to
  # send fancy escape sequences (MVP 1 can't draw them anyway).
  defp build_env(overrides) do
    System.get_env()
    |> Map.drop(["COLORTERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION"])
    |> Map.put("TERM", "dumb")
    |> Map.merge(overrides)
    |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
  end

  @impl true
  def handle_call({:attach_parser, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, arm(%{state | parser: pid})}
  end

  @impl true
  def handle_cast({:write, bytes}, state) do
    {:noreply, flush(%{state | pending: state.pending <> bytes})}
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

  defp drain(state, reads_left) do
    case PtyNif.read(state.pty) do
      {:ok, bytes} ->
        send(state.parser, {:pty_data, bytes})
        drain(state, reads_left - 1)

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

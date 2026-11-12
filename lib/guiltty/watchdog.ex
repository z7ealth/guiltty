defmodule Guiltty.Watchdog do
  @moduledoc """
  Warns when a process is about to cause trouble, before anyone notices
  the machine slowing down.

  The BEAM can report two things about any process (`erlang:system_monitor/2`):

    * `long_gc` - a garbage collection took longer than `@long_gc_ms`. The
      process was frozen that long: a tab that stutters.
    * `large_heap` - a collection left the heap bigger than `@large_heap_mb`.
      A tab is killed at 2 GB (`Guiltty.Session.limit_memory/1`); this
      warns long before.

  Each warning goes to the log, naming the process by its role (`{7,
  :screen}` is tab 7's screen), and out as telemetry,
  `[:guiltty, :watchdog, kind]`. One warning per process per minute, so a
  flood doesn't flood the log too.

  Only one process in a node can be the system monitor: starting this one
  replaces any other, and stopping it turns monitoring off.
  """

  use GenServer

  require Logger

  @long_gc_ms 100
  @large_heap_mb 256
  @quiet_ms 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    long_gc = Keyword.get(opts, :long_gc_ms, @long_gc_ms)
    words = div(Keyword.get(opts, :large_heap_mb, @large_heap_mb) * 1024 * 1024, 8)
    :erlang.system_monitor(self(), long_gc: long_gc, large_heap: words)
    # %{pid => monotonic ms of its last warning}
    {:ok, %{warned: %{}}}
  end

  @impl true
  def handle_info({:monitor, pid, kind, info}, state) when kind in [:long_gc, :large_heap] do
    now = System.monotonic_time(:millisecond)

    case state.warned do
      %{^pid => last} when now - last < @quiet_ms ->
        {:noreply, state}

      _ ->
        warn(pid, kind, info)
        {:noreply, %{state | warned: Map.put(state.warned, pid, now)}}
    end
  end

  # The other system monitor events (ports, other options) aren't asked for.
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    :erlang.system_monitor(:undefined)
    :ok
  end

  defp warn(pid, kind, info) do
    who = name(pid)
    # Both sizes are in words; timeout is in milliseconds.
    ms = Keyword.get(info, :timeout, 0)

    mb =
      div(
        (Keyword.get(info, :heap_size, 0) + Keyword.get(info, :old_heap_size, 0)) * 8,
        1_048_576
      )

    case kind do
      :long_gc ->
        Logger.warning("watchdog: #{who} paused #{ms} ms to collect garbage (heap #{mb} MB)")

      :large_heap ->
        Logger.warning("watchdog: #{who} has a #{mb} MB heap")
    end

    :telemetry.execute([:guiltty, :watchdog, kind], %{ms: ms, heap_mb: mb}, %{pid: pid, name: who})
  end

  # A session's processes and a desk's are named in the Registry by role.
  defp name(pid) do
    case Registry.keys(Guiltty.Registry, pid) do
      [key | _] -> inspect(key)
      [] -> pid |> Process.info(:registered_name) |> registered(pid)
    end
  end

  defp registered({:registered_name, name}, _pid) when is_atom(name), do: inspect(name)
  defp registered(_, pid), do: inspect(pid)
end

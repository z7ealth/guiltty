defmodule Guiltty.Audio do
  @moduledoc """
  The visualizer's ears: while the `visualizer` setting is on, runs
  `priv/guiltty_audio` behind a port and passes on how loud each band of
  what the speakers play is, about 30 times a second, to every window
  listening. Book chapter 30.

  A window listens with `listen/0` and then gets `{:audio, levels}`:
  one byte per band, lowest frequencies first, 0 (silent) to 255. As
  soon as the helper runs, every band is sent at 0, so the bars take
  their room in the tab bar for as long as the visualizer is on, sound
  or not. An empty binary means "no bars": the sound stopped being
  analyzed (the setting went off, or the helper ended). While nothing
  plays, nothing more is sent. A window that starts listening later is
  told the current levels at once.

  Listeners are kept in a `Registry` with duplicate keys (`Guiltty.PubSub`,
  started by the application), not here: a window's registration lasts
  as long as the window, even if this process restarts, and goes away by
  itself when the window ends. Sending to every listener is
  `Registry.dispatch/3`.

  The helper may not be able to run: no PipeWire on this machine (exit
  status 2), or PipeWire refusing (3). The first is said once in the log,
  and the helper isn't tried again until the setting is turned off and on;
  anything else is tried again after `@retry_ms`.
  """

  use GenServer

  require Logger

  alias Guiltty.Config

  # Keep in sync with c_src/audio/guiltty_audio.c.
  @version 1
  @hello 1
  @levels 2
  # The helper's band_count: the silent bars sent before any sound.
  @bands 16

  @retry_ms 10_000

  @doc """
  Options: `:name` (default `Guiltty.Audio`, nil for none), `:enabled`
  (over the config's `visualizer`; the tests use it), `:args` (for the
  helper: `["--raw", path]` analyzes a file instead of recording).
  """
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  The calling process gets `{:audio, levels}` from now on, until it
  ends. A no-op when the registry isn't running (a window in a test).
  Listening twice is listening once: duplicate keys would otherwise
  register the process twice, and every level would arrive twice.
  """
  def listen do
    if Process.whereis(Guiltty.PubSub) && :audio not in Registry.keys(Guiltty.PubSub, self()) do
      Registry.register(Guiltty.PubSub, :audio, nil)
      if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, {:tell, self()})
    end

    :ok
  end

  @impl true
  def init(opts) do
    if Process.whereis(Config) && !Keyword.has_key?(opts, :enabled),
      do: Config.subscribe(self())

    enabled =
      Keyword.get_lazy(opts, :enabled, fn -> Map.get(Config.get(), :visualizer, false) end)

    state = %{
      port: nil,
      enabled: false,
      args: Keyword.get(opts, :args, []),
      gave_up: false,
      # what the listeners were last sent: <<>> is no bars
      levels: <<>>
    }

    {:ok, set_enabled(state, enabled)}
  end

  @impl true
  def handle_cast({:tell, pid}, state) do
    if state.levels != <<>>, do: send(pid, {:audio, state.levels})
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, <<@hello, version::16>>}}, %{port: port} = state) do
    if version == @version do
      {:noreply, broadcast(state, :binary.copy(<<0>>, @bands))}
    else
      Logger.warning("audio: guiltty_audio speaks version #{version}, not #{@version}")
      {:noreply, stop_helper(%{state | gave_up: true})}
    end
  end

  def handle_info({port, {:data, <<@levels, n, levels::binary-size(n)>>}}, %{port: port} = state) do
    {:noreply, broadcast(state, levels)}
  end

  def handle_info({port, {:data, other}}, %{port: port} = state) do
    Logger.warning("audio: unexpected message from guiltty_audio: #{inspect(other)}")
    {:noreply, stop_helper(state)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    state = broadcast(%{state | port: nil}, <<>>)

    case status do
      2 ->
        Logger.notice("audio: no PipeWire on this machine, so no visualizer")
        {:noreply, %{state | gave_up: true}}

      _ ->
        Logger.warning("audio: guiltty_audio exited with status #{status}; trying again soon")
        Process.send_after(self(), :retry, @retry_ms)
        {:noreply, state}
    end
  end

  def handle_info(:retry, state), do: {:noreply, start_helper(state)}

  def handle_info({:config, config}, state),
    do: {:noreply, set_enabled(state, Map.get(config, :visualizer, false))}

  def handle_info({:config_error, _message}, state), do: {:noreply, state}

  defp set_enabled(%{enabled: same} = state, same), do: state
  # Turned on: try again even if it gave up (PipeWire may be there now).
  defp set_enabled(state, true), do: start_helper(%{state | enabled: true, gave_up: false})
  defp set_enabled(state, false), do: stop_helper(%{state | enabled: false})

  defp start_helper(%{enabled: true, port: nil, gave_up: false} = state) do
    port =
      Port.open({:spawn_executable, Path.join(:code.priv_dir(:guiltty), "guiltty_audio")}, [
        :binary,
        :exit_status,
        :use_stdio,
        packet: 4,
        args: state.args
      ])

    %{state | port: port}
  end

  defp start_helper(state), do: state

  # Closing the port closes the helper's stdin: it stops recording and
  # exits. No exit status arrives for a port closed from this side.
  defp stop_helper(%{port: nil} = state), do: state

  defp stop_helper(%{port: port} = state) do
    Port.close(port)
    broadcast(%{state | port: nil}, <<>>)
  end

  defp broadcast(state, levels) do
    if Process.whereis(Guiltty.PubSub) do
      Registry.dispatch(Guiltty.PubSub, :audio, fn listeners ->
        for {pid, _} <- listeners, do: send(pid, {:audio, levels})
      end)
    end

    %{state | levels: levels}
  end
end

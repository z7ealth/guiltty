defmodule Guiltty.Lifeline do
  @moduledoc """
  Keeps guiltty running while it has a desk (a window, or a closed window's
  locked tabs). When the last desk ends, this process stops; it's
  significant in the application's supervisor, so guiltty stops with it.

  Desks are started with `open/1`, which tells this process to watch them.
  A desk that crashes is restarted by `Guiltty.Desks`; this process finds
  the new one by its registered name before counting it as gone.
  """

  use GenServer, restart: :transient

  require Logger

  alias Guiltty.Desk

  @desks Guiltty.Desks

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Opens a window. If a closed window kept locked tabs (its desk is
  windowless), that one comes back first, the oldest of them; otherwise a
  new desk starts with these options (see `Guiltty.Desk`), and is watched.
  With `fresh: true` it's always a new desk (Ctrl+Shift+N). Returns
  `{:ok, desk_id}`.
  """
  def open(opts \\ []), do: GenServer.call(__MODULE__, {:open, opts})

  @doc """
  A window got the keyboard: `tabs` is its desk's `Guiltty.Tabs`. A
  `guiltty` command run from outside guiltty (no `GUILTTY_PANE`) acts on
  that window. Safe to call with no Lifeline running (tests).
  """
  def focused(tabs), do: GenServer.cast(__MODULE__, {:focused, tabs})

  @doc """
  The Tabs of the window that last had the keyboard, if it's still
  running; else the newest desk's; nil with no desk at all.
  """
  def last_focused, do: GenServer.call(__MODULE__, :last_focused)

  @impl true
  def init(_opts) do
    # Desks already running (this process restarted): watch them again.
    watched =
      Map.new(Desk.all(), fn desk ->
        pid = GenServer.whereis(Desk.name(desk))
        {Process.monitor(pid), desk}
      end)

    {:ok, %{watched: watched, focused: nil}}
  end

  @impl true
  def handle_call({:open, opts}, _from, state) do
    {fresh?, opts} = Keyword.pop(opts, :fresh, false)
    windowless = if fresh?, do: nil, else: Enum.find(Enum.sort(Desk.all()), &Desk.windowless?/1)

    case windowless && Desk.reopen(windowless, Keyword.get(opts, :window, [])) do
      :ok -> {:reply, {:ok, windowless}, state}
      _none_or_failed -> start_desk(opts, state)
    end
  end

  def handle_call(:last_focused, _from, state) do
    alive = state.focused && GenServer.whereis(state.focused) && state.focused

    newest =
      case Desk.all() do
        [] -> nil
        desks -> Desk.tabs(Enum.max(desks))
      end

    {:reply, alive || newest, state}
  end

  @impl true
  def handle_cast({:focused, tabs}, state), do: {:noreply, %{state | focused: tabs}}

  defp start_desk(opts, state) do
    desk = System.unique_integer([:positive, :monotonic])
    spec = {Desk, Keyword.put(opts, :desk, desk)}

    case DynamicSupervisor.start_child(@desks, spec) do
      {:ok, pid} -> {:reply, {:ok, desk}, watch(state, desk, pid)}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.watched, ref) do
    {desk, watched} = Map.pop(state.watched, ref)
    state = %{state | watched: watched}

    if reason in [:normal, :shutdown] or match?({:shutdown, _}, reason) do
      gone(state)
    else
      # Crashed: Desks starts it again under the same name. Look for it.
      Process.send_after(self(), {:find, desk, 20}, 50)
      {:noreply, state}
    end
  end

  def handle_info({:find, desk, tries}, state) do
    case GenServer.whereis(Desk.name(desk)) do
      pid when is_pid(pid) ->
        {:noreply, watch(state, desk, pid)}

      nil when tries > 0 ->
        Process.send_after(self(), {:find, desk, tries - 1}, 50)
        {:noreply, state}

      nil ->
        gone(state)
    end
  end

  defp watch(state, desk, pid),
    do: %{state | watched: Map.put(state.watched, Process.monitor(pid), desk)}

  defp gone(%{watched: watched} = state) when map_size(watched) == 0 do
    Logger.info("lifeline: the last window and its tabs are gone")
    {:stop, {:shutdown, :last_desk_closed}, state}
  end

  defp gone(state), do: {:noreply, state}
end

defmodule Guiltty.Session.Screen do
  @moduledoc """
  The authoritative screen of one session.

  Applies parser commands to a `Guiltty.Grid` and sends changed rows to
  subscribers (the `Window`, from step 5) as
  `{:screen_update, id, rows, cursor}`. A new subscriber first gets every row.
  """

  use GenServer

  alias Guiltty.Grid
  alias Guiltty.Session

  def start_link(opts) do
    Session.start_named(opts[:id], :screen, &GenServer.start_link(__MODULE__, opts, name: &1))
  end

  def apply(id, commands), do: GenServer.cast(Session.via(id, :screen), {:apply, commands})

  @doc "The screen as text."
  def dump(id), do: GenServer.call(Session.via(id, :screen), :dump)

  def subscribe(id, pid), do: GenServer.call(Session.via(id, :screen), {:subscribe, pid})

  @impl true
  def init(opts) do
    grid = Grid.new(Keyword.get(opts, :cols, 80), Keyword.get(opts, :rows, 24))
    {:ok, %{id: opts[:id], grid: grid, subscribers: MapSet.new()}}
  end

  @impl true
  def handle_cast({:apply, commands}, state) do
    {rows, grid} = state.grid |> Grid.apply(commands) |> Grid.take_dirty()
    notify(state.subscribers, state.id, rows, Grid.cursor(grid))
    {:noreply, %{state | grid: grid}}
  end

  @impl true
  def handle_call(:dump, _from, state), do: {:reply, Grid.dump(state.grid), state}

  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    notify([pid], state.id, Grid.snapshot(state.grid), Grid.cursor(state.grid))
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  defp notify(_subscribers, _id, [], _cursor), do: :ok

  defp notify(subscribers, id, rows, cursor) do
    Enum.each(subscribers, &send(&1, {:screen_update, id, rows, cursor}))
  end
end

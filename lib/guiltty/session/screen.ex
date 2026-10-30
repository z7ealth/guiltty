defmodule Guiltty.Session.Screen do
  @moduledoc """
  The authoritative screen of one session.

  Applies parser commands to a `Guiltty.Grid` (through `Guiltty.Terminal`)
  and sends what changed to subscribers (the `Window`) as
  `{:screen_update, id, update}`, where `update` is a map with `:size`
  (`{cols, rows}`), `:rows` (`[{index, row}]`), `:cursor` (`{row, col}`),
  `:cursor_visible`, `:title` and `:input` (the modes that change what keys,
  paste and the mouse send). A new subscriber first gets every row.

  When a program asks the terminal something (its type, the cursor
  position), the answer is written back to it through the `Pty`.
  """

  use GenServer

  alias Guiltty.{Grid, Session, Terminal}
  alias Guiltty.Session.Pty

  def start_link(opts) do
    Session.start_named(opts[:id], :screen, &GenServer.start_link(__MODULE__, opts, name: &1))
  end

  def apply(id, commands), do: GenServer.cast(Session.via(id, :screen), {:apply, commands})

  @doc "The screen as text."
  def dump(id), do: GenServer.call(Session.via(id, :screen), :dump)

  def subscribe(id, pid), do: GenServer.call(Session.via(id, :screen), {:subscribe, pid})

  @doc "Resizes the grid (no reflow) and sends every row to subscribers."
  def resize(id, cols, rows), do: GenServer.call(Session.via(id, :screen), {:resize, cols, rows})

  @impl true
  def init(opts) do
    grid = Grid.new(Keyword.get(opts, :cols, 80), Keyword.get(opts, :rows, 24))
    {:ok, %{id: opts[:id], grid: grid, subscribers: MapSet.new(), sent_state: nil}}
  end

  @impl true
  def handle_cast({:apply, commands}, state) do
    {:noreply, state |> update_grid(&Terminal.apply(&1, commands)) |> flush()}
  end

  @impl true
  def handle_call(:dump, _from, state), do: {:reply, Grid.dump(state.grid), state}

  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    send(pid, {:screen_update, state.id, update(state.grid, Grid.snapshot(state.grid))})
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  def handle_call({:resize, cols, rows}, _from, state) do
    {:reply, :ok, state |> update_grid(&Grid.resize(&1, cols, rows)) |> flush()}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  defp update_grid(state, fun), do: %{state | grid: fun.(state.grid)}

  # Answer the program's queries, then send the dirty rows, or just the
  # rest if only the cursor, the title or a mode changed.
  defp flush(state) do
    {responses, grid} = Grid.take_responses(state.grid)
    if responses != [], do: Pty.write(state.id, IO.iodata_to_binary(responses))

    {rows, grid} = Grid.take_dirty(grid)
    sent = {Grid.cursor(grid), grid.cursor_visible, grid.title, grid.input}

    if rows != [] or sent != state.sent_state do
      update = update(grid, rows)
      Enum.each(state.subscribers, &send(&1, {:screen_update, state.id, update}))
    end

    %{state | grid: grid, sent_state: sent}
  end

  defp update(grid, rows) do
    %{
      size: {grid.cols, grid.rows},
      rows: rows,
      cursor: Grid.cursor(grid),
      cursor_visible: grid.cursor_visible,
      title: grid.title,
      input: grid.input
    }
  end
end

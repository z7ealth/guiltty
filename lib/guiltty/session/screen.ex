defmodule Guiltty.Session.Screen do
  @moduledoc """
  The authoritative screen of one session.

  Applies parser commands to a `Guiltty.Grid` (through `Guiltty.Terminal`).
  When a program asks the terminal something (its type, the cursor
  position), the answer is written back to it through the `Pty`.

  ## Viewing it

  One process at a time can *view* the screen (the `Window`, for the active
  tab). Changes aren't pushed to it one by one: the Screen sends
  `{:screen_dirty, id}` once, and the viewer calls `take_update/1` when it's
  ready for the next frame. Everything that changed in between comes in one
  update, so a flood of output costs the window one update per frame, not
  one per chunk.

  An update is a map with `:size` (`{cols, rows}`), `:rows` (`[{index, row}]`),
  `:cursor` (`{row, col}`), `:cursor_visible`, `:title` and `:input` (the
  modes that change what keys, paste and the mouse send).

  Title changes also go to `opts[:owner]` (the tab manager) as
  `{:title, id, title}`.
  """

  use GenServer

  alias Guiltty.{Grid, Session, Terminal}
  alias Guiltty.Session.Pty

  def start_link(opts) do
    Session.start_named(opts[:id], :screen, &GenServer.start_link(__MODULE__, opts, name: &1))
  end

  @doc "Applies commands. Returns once they're on the screen (the parser waits on it)."
  def apply(id, commands), do: GenServer.call(Session.via(id, :screen), {:apply, commands})

  @doc "The screen as text."
  def dump(id), do: GenServer.call(Session.via(id, :screen), :dump)

  @doc "Makes `pid` the viewer. It gets `{:screen_dirty, id}` right away (everything is new to it)."
  def subscribe(id, pid), do: GenServer.call(Session.via(id, :screen), {:subscribe, pid})

  @doc "Stops `pid` from viewing (if it is the viewer)."
  def unsubscribe(id, pid), do: GenServer.call(Session.via(id, :screen), {:unsubscribe, pid})

  @doc "Everything that changed since the last update, as a map (see the moduledoc)."
  def take_update(id), do: GenServer.call(Session.via(id, :screen), :take_update)

  @doc "Resizes the grid (no reflow)."
  def resize(id, cols, rows), do: GenServer.call(Session.via(id, :screen), {:resize, cols, rows})

  @doc "The current title."
  def title(id), do: GenServer.call(Session.via(id, :screen), :title)

  @doc "The grid's `{cols, rows}`."
  def size(id), do: GenServer.call(Session.via(id, :screen), :size)

  @impl true
  def init(opts) do
    grid = Grid.new(Keyword.get(opts, :cols, 80), Keyword.get(opts, :rows, 24))

    {:ok,
     %{
       id: opts[:id],
       owner: opts[:owner],
       grid: grid,
       viewer: nil,
       viewer_ref: nil,
       # whether the viewer was told about changes it hasn't taken yet
       notified: false,
       sent_state: nil,
       title: ""
     }}
  end

  @impl true
  def handle_call({:apply, commands}, _from, state) do
    {:reply, :ok, state |> update_grid(&Terminal.apply(&1, commands)) |> after_change()}
  end

  def handle_call(:dump, _from, state), do: {:reply, Grid.dump(state.grid), state}
  def handle_call(:title, _from, state), do: {:reply, state.grid.title, state}
  def handle_call(:size, _from, state), do: {:reply, {state.grid.cols, state.grid.rows}, state}

  def handle_call({:subscribe, pid}, _from, state) do
    if state.viewer_ref, do: Process.demonitor(state.viewer_ref, [:flush])

    state = %{
      state
      | viewer: pid,
        viewer_ref: Process.monitor(pid),
        grid: Grid.mark_all_dirty(state.grid),
        sent_state: nil,
        notified: false
    }

    {:reply, :ok, notify(state)}
  end

  def handle_call({:unsubscribe, pid}, _from, %{viewer: pid} = state) do
    Process.demonitor(state.viewer_ref, [:flush])
    {:reply, :ok, %{state | viewer: nil, viewer_ref: nil, notified: false}}
  end

  def handle_call({:unsubscribe, _pid}, _from, state), do: {:reply, :ok, state}

  def handle_call(:take_update, _from, state) do
    {rows, grid} = Grid.take_dirty(state.grid)
    state = %{state | grid: grid, notified: false, sent_state: viewer_state(grid)}
    {:reply, update(grid, rows), state}
  end

  def handle_call({:resize, cols, rows}, _from, state) do
    {:reply, :ok, state |> update_grid(&Grid.resize(&1, cols, rows)) |> after_change()}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{viewer_ref: ref} = state) do
    {:noreply, %{state | viewer: nil, viewer_ref: nil, notified: false}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  defp update_grid(state, fun), do: %{state | grid: fun.(state.grid)}

  defp after_change(state), do: state |> answer_queries() |> report_title() |> notify()

  defp answer_queries(state) do
    {responses, grid} = Grid.take_responses(state.grid)
    if responses != [], do: Pty.write(state.id, IO.iodata_to_binary(responses))
    %{state | grid: grid}
  end

  defp report_title(%{grid: %{title: title}, title: title} = state), do: state

  defp report_title(state) do
    if state.owner, do: send(state.owner, {:title, state.id, state.grid.title})
    %{state | title: state.grid.title}
  end

  # Tell the viewer once that there's something new to take.
  defp notify(%{viewer: nil} = state), do: state
  defp notify(%{notified: true} = state), do: state

  defp notify(state) do
    if MapSet.size(state.grid.dirty) > 0 or viewer_state(state.grid) != state.sent_state do
      send(state.viewer, {:screen_dirty, state.id})
      %{state | notified: true}
    else
      state
    end
  end

  defp viewer_state(grid), do: {Grid.cursor(grid), grid.cursor_visible, grid.title, grid.input}

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

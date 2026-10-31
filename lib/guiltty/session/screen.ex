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
  `:clusters` (`[{id, text}]`, the clusters the viewer hasn't seen yet),
  `:cursor` (`{row, col}`), `:cursor_visible`, `:title`, `:input` (the
  modes that change what keys, paste and the mouse send), `:scroll` and
  `:scrollback` (how far back the view is, and how far it could go).

  ## The view

  The viewer can scroll back, select text and search (see `Guiltty.View`).
  That state lives here, next to the grid it points into. While the view
  is scrolled back, new output doesn't move it: it stays on the same text.

  Title changes also go to `opts[:owner]` (the tab manager) as
  `{:title, id, title}`.
  """

  use GenServer

  alias Guiltty.{Config, Grid, Search, Selection, Session, Terminal, View}
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

  @doc """
  Scrolls the view: `{:lines, n}` (positive is back, into the scrollback),
  `:page_up`, `:page_down`, `:top` or `:bottom` (back to the live screen).
  """
  def scroll(id, how), do: GenServer.call(Session.via(id, :screen), {:scroll, how})

  @doc """
  Mouse selection at a visible `{row, col}`: `{:start, pos, clicks}`
  (1 = by character, 2 = by word, 3 = by line), `{:extend, pos}`, or
  `:finish`, which returns the selected text (nil for a plain click, which
  clears the selection instead).
  """
  def select(id, action), do: GenServer.call(Session.via(id, :screen), {:select, action})

  @doc "The selected text, or nil."
  def selection_text(id), do: GenServer.call(Session.via(id, :screen), :selection_text)

  def clear_selection(id), do: GenServer.call(Session.via(id, :screen), :clear_selection)

  @doc """
  Searches for `query`: `:start` from the newest output, then `:older` or
  `:newer` from the current match. Scrolls the view to the match and marks
  every match in view. Returns `:found` or `:not_found`.
  """
  def search(id, query, direction),
    do: GenServer.call(Session.via(id, :screen), {:search, query, direction})

  def end_search(id), do: GenServer.call(Session.via(id, :screen), :end_search)

  @impl true
  def init(opts) do
    scrollback = Keyword.get_lazy(opts, :scrollback, fn -> Config.get().scrollback end)

    grid =
      Grid.new(Keyword.get(opts, :cols, 80), Keyword.get(opts, :rows, 24), scrollback: scrollback)

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
       # cluster ids below this one were sent to the viewer
       sent_clusters: 0,
       title: "",
       scroll: 0,
       selection: nil,
       # the text it held when the mouse let go: if the text under it
       # changes, the selection goes (see drop_stale_selection/1)
       selected_text: nil,
       # %{query: binary, match: Search.match() | nil}
       search: nil,
       # the last update was decorated (see Guiltty.View): the next plain one
       # must send every row
       decorated: false
     }}
  end

  @impl true
  def handle_call({:apply, commands}, _from, state) do
    history = state.grid.history
    state = update_grid(state, &Terminal.apply(&1, commands))
    {:reply, :ok, state |> keep_view(history) |> after_change()}
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
        sent_clusters: 0,
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
    decorated = View.decorated?(state.scroll, state.selection, state.search)

    grid =
      if state.decorated and not decorated, do: Grid.mark_all_dirty(state.grid), else: state.grid

    {rows, grid} = Grid.take_dirty(grid)

    rows =
      if decorated, do: View.rows(grid, state.scroll, state.selection, state.search), else: rows

    clusters = Grid.clusters_since(grid, state.sent_clusters)

    update = update(grid, rows, clusters, state)

    state = %{
      state
      | grid: grid,
        notified: false,
        sent_state: viewer_state(state, grid),
        sent_clusters: grid.next_cluster,
        decorated: decorated
    }

    {:reply, update, state}
  end

  def handle_call({:resize, cols, rows}, _from, state) do
    state = %{state | selection: nil} |> update_grid(&Grid.resize(&1, cols, rows))
    {:reply, :ok, state |> keep_view(state.grid.history) |> after_change()}
  end

  def handle_call({:scroll, how}, _from, state) do
    page = state.grid.rows - 1

    scroll =
      case how do
        {:lines, n} -> state.scroll + n
        :page_up -> state.scroll + page
        :page_down -> state.scroll - page
        :top -> Grid.scrollback_size(state.grid)
        :bottom -> 0
      end

    {:reply, :ok, notify(%{state | scroll: View.clamp_scroll(state.grid, scroll)})}
  end

  def handle_call({:select, {:start, pos, clicks}}, _from, state) do
    selection = Selection.new(position(state, pos), clicks)
    {:reply, :ok, notify(%{state | selection: selection, selected_text: nil})}
  end

  def handle_call({:select, {:extend, pos}}, _from, %{selection: %Selection{} = sel} = state) do
    {:reply, :ok, notify(%{state | selection: Selection.extend(sel, position(state, pos))})}
  end

  # A click that didn't move: no selection, just a click.
  def handle_call(
        {:select, :finish},
        _from,
        %{selection: %{mode: :char, anchor: p, head: p}} = state
      ),
      do: {:reply, nil, notify(%{state | selection: nil})}

  def handle_call({:select, :finish}, _from, %{selection: %Selection{} = sel} = state) do
    text = Selection.text(state.grid, sel)
    {:reply, text, %{state | selected_text: text}}
  end

  def handle_call({:select, _action}, _from, state), do: {:reply, nil, state}

  def handle_call(:selection_text, _from, %{selection: nil} = state), do: {:reply, nil, state}

  def handle_call(:selection_text, _from, state),
    do: {:reply, Selection.text(state.grid, state.selection), state}

  def handle_call(:clear_selection, _from, state),
    do: {:reply, :ok, notify(%{state | selection: nil})}

  def handle_call({:search, query, direction}, _from, state) do
    from =
      case {direction, state.search} do
        {:start, _} -> nil
        {_, %{match: {n, col, _}}} -> {n, col}
        _ -> nil
      end

    direction = if direction == :start, do: :older, else: direction

    case Search.find(state.grid, query, from, direction) do
      nil ->
        # Stepping past the last match keeps it marked: there's just no
        # other one. A new query with no match marks nothing.
        match = if from, do: state.search.match
        {:reply, :not_found, notify(%{state | search: %{query: query, match: match}})}

      {n, _c1, _c2} = match ->
        state = %{state | search: %{query: query, match: match}} |> show_row(n)
        {:reply, :found, notify(state)}
    end
  end

  def handle_call(:end_search, _from, state), do: {:reply, :ok, notify(%{state | search: nil})}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{viewer_ref: ref} = state) do
    {:noreply, %{state | viewer: nil, viewer_ref: nil, notified: false}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  defp update_grid(state, fun), do: %{state | grid: fun.(state.grid)}

  # Scrolled back, new rows entering the scrollback would move the text up
  # under the viewer: scroll back as many rows to stay on the same text.
  defp keep_view(%{scroll: 0} = state, _history), do: state

  defp keep_view(state, history) do
    scroll = View.clamp_scroll(state.grid, state.scroll + state.grid.history - history)
    %{state | scroll: scroll}
  end

  # A visible {row, col} to a position in row numbers (see Guiltty.Grid).
  defp position(state, {row, col}) do
    row = min(max(row, 0), state.grid.rows - 1)
    {View.top(state.grid, state.scroll) + row, min(col, state.grid.cols - 1)}
  end

  # Scroll so that row number n is in view, near the middle if it wasn't.
  defp show_row(state, n) do
    top = View.top(state.grid, state.scroll)

    if n >= top and n < top + state.grid.rows do
      state
    else
      scroll = state.grid.history - (n - div(state.grid.rows, 2))
      %{state | scroll: View.clamp_scroll(state.grid, scroll)}
    end
  end

  defp after_change(state) do
    state |> answer_queries() |> report_title() |> drop_stale_selection() |> notify()
  end

  # A selection points at rows by number, so it follows its text as output
  # scrolls. But when the text itself changes under it (`clear`, a program
  # redrawing), highlighting whatever is there now would be wrong: the
  # selection goes, as in other terminals. Comparing the text, not "did
  # these rows change", keeps a selection that merely scrolled.
  defp drop_stale_selection(%{selection: %Selection{} = sel, selected_text: text} = state)
       when is_binary(text) do
    if Selection.text(state.grid, sel) == text,
      do: state,
      else: %{state | selection: nil, selected_text: nil}
  end

  defp drop_stale_selection(state), do: state

  defp answer_queries(state) do
    {responses, grid} = Grid.take_responses(state.grid)
    if responses != [], do: Pty.answer(state.id, Enum.map(responses, &IO.iodata_to_binary/1))
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
    if Grid.dirty?(state.grid) or viewer_state(state, state.grid) != state.sent_state do
      send(state.viewer, {:screen_dirty, state.id})
      %{state | notified: true}
    else
      state
    end
  end

  defp viewer_state(state, grid) do
    {Grid.cursor(grid), grid.cursor_visible, grid.cursor_style, grid.title, grid.input, grid.alt?,
     state.scroll, state.selection, state.search, Grid.scrollback_size(grid)}
  end

  defp update(grid, rows, clusters, state) do
    cursor = View.cursor(grid, state.scroll)

    %{
      size: {grid.cols, grid.rows},
      rows: rows,
      clusters: clusters,
      cursor: cursor || {0, 0},
      cursor_visible: grid.cursor_visible and cursor != nil,
      cursor_style: grid.cursor_style,
      title: grid.title,
      input: grid.input,
      alt_screen: grid.alt?,
      scroll: state.scroll,
      scrollback: Grid.scrollback_size(grid)
    }
  end
end

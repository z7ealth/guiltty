defmodule Guiltty.Tabs do
  @moduledoc """
  One window's tabs: which there are, in which order, which one is
  active, how each is split into panes, and their titles. Every window has
  its own (`Guiltty.Desk`), so windows are independent: their tabs, locked
  tabs and broadcast groups never mix. Every function takes the desk's
  Tabs (`Guiltty.Desk.tabs/1`, or a pid).

  ## Tabs and panes

  A tab is split into one or more *panes* (`Guiltty.Layout`, a tree), and
  each pane is a session (`Guiltty.Session.Supervisor`) started under the
  `Guiltty.Sessions` DynamicSupervisor, with an integer id unique across
  all desks. One pane of the tab has the *focus*: it's what you type into.
  A tab's id is the id of the session it was opened with, so a tab of one
  pane is named like its session. The id stays the tab's when that first
  pane closes.

  Sessions are registered with their desk's id, so if this process
  crashes, the new one takes back its own sessions, and only those, each
  as a tab of its own: the layouts are lost with the crash.

  A window registers with `attach_window/2` and then gets `{:tabs, info}`
  whenever something changes. `info` is a map:

    * `:list` - `[{tab, title}]`, in order; a tab's name (`rename/3`), or
      else its focused pane's title
    * `:active` - the active tab's id
    * `:panes` - the active tab's panes: `%{focus: session, rects: %{session
      => {x, y, w, h}}, separators: [separator]}` (see `Guiltty.Layout.rects/2`)
    * `:members` - `%{tab => [session]}`, each tab's panes
    * `:size` - `{cols, rows}`, the whole grid every tab is laid out in
    * `:locked` - the tabs that stay when the window closes (`toggle_lock/1`)
    * `:group` - the broadcast group, `%{session => host}`, or `:local` for
      a local pane (`toggle_broadcast/3`)
    * `:lost` - group panes whose connection is gone (broadcast is paused)
    * `:marks` - `%{tab => :activity | :bell}`: tabs that printed something,
      or rang the bell, since you last looked at them (see
      `Guiltty.Session.Screen`, "Marks")

  ## Broadcast

  Typing in one pane of the broadcast group goes to every pane in it, to
  do the same thing on several servers at once. Joining is per tab: every
  pane of the tab joins (or leaves) together, so a tab split in four, with
  an ssh in each, types into four servers. A pane joins only while it's
  running one of the allowed programs (ssh, by default), and joining
  records that program's process. Before any keystroke goes out, every
  pane is checked: is that same process still in its terminal's
  foreground? If an ssh has exited, its pane's foreground is the local
  shell again, and the keystroke goes *nowhere*: the broadcast pauses
  until the lost pane's tab leaves the group (or it closes). The same
  check runs every second, so the tab is marked before you type.

  Your own machine can be in the group too, as a *local* pane: joined on
  purpose (`toggle_broadcast(tab, programs, local: true)`), and not
  checked, since there's no connection to lose. (Checking would not work
  either: in a local pane every command you run takes the foreground.)

  A pane ends when its shell exits (or `close/2`), and a tab when its last
  pane does. When the last tab ends, this process stops; it's significant
  in its desk, so the desk stops with it (and guiltty, if it was the last
  desk: `Guiltty.Lifeline`).
  """

  use GenServer, restart: :transient

  require Logger

  alias Guiltty.{Config, Layout, Session}
  alias Guiltty.Session.Pty

  @sessions Guiltty.Sessions

  @doc """
  Options: `:desk` (the desk's id; its sessions are registered with it),
  `:name`, `:cwd` (where the first tab starts, when the config's
  `working_directory` is `:inherit`: the folder `guiltty` was run in) and
  `:session_opts` (merged into every session's, for tests).
  """
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc """
  Opens a new tab after the active one and makes it active. Returns
  `{:ok, id}`. Options go to its session, over the config's: `:shell`
  and `:args` run a program instead of the shell (the tab closes when it
  exits).
  """
  def new_tab(tabs, opts \\ []), do: GenServer.call(tabs, {:new_tab, opts})

  @doc """
  Splits the focused pane of the active tab: a new pane goes `:right` of it
  or `:down` (below), with half its room, and gets the focus. Returns
  `{:ok, session}`, or `{:error, :too_small}` when the pane has no room
  for two.
  """
  def split(tabs, direction, opts \\ []), do: GenServer.call(tabs, {:split, direction, opts})

  @doc """
  Moves the focus in the active tab: to the pane `:left`, `:right`, `:up`
  or `:down` of the focused one, or to `{:pane, session}`.
  """
  def focus(tabs, to), do: GenServer.call(tabs, {:focus, to})

  @doc """
  Moves the separator nearest the focused pane, across `direction`, by
  `cells` (see `Guiltty.Layout.resize/5`).
  """
  def resize_pane(tabs, direction, cells \\ 2),
    do: GenServer.call(tabs, {:resize_pane, direction, cells})

  @doc "Closes a pane (a session; its shell gets SIGHUP), and its tab when it's the last."
  def close(tabs, id), do: GenServer.call(tabs, {:close, id})

  @doc """
  Locks or unlocks a tab. Closing the window closes every tab but the
  locked ones; those keep running, and the window comes back with them.
  """
  def toggle_lock(tabs, tab), do: GenServer.call(tabs, {:toggle_lock, tab})

  @doc """
  Closes every tab that isn't locked (each shell gets SIGHUP). If none is
  locked, the last one ending stops Tabs, and its desk with it.
  """
  def close_unlocked(tabs), do: GenServer.call(tabs, :close_unlocked)

  @doc """
  Puts every pane of a tab in the broadcast group, or takes them out. To
  join, each pane's foreground program must be one of `programs`; with
  `local: true` the others join as local panes. Returns `{:ok, :joined}`,
  `{:ok, :left}` or `{:error, {:not_allowed, program}}` (and nothing
  joins). `tab` may also be one of its panes.
  """
  def toggle_broadcast(tabs, tab, programs, opts \\ []),
    do: GenServer.call(tabs, {:toggle_broadcast, tab, programs, opts})

  @doc """
  Sends typed input from pane `id`. In a broadcast group of two or more, it
  goes to every pane in the group, but only if every one still runs what
  it joined with; otherwise to nobody, and `{:paused, lost_ids}` comes
  back. Outside a group it goes to that pane alone.
  """
  def send_input(tabs, id, bytes), do: GenServer.call(tabs, {:send_input, id, bytes})

  @doc "Switches to `:next`, `:prev`, or the tab at a 0-based index."
  def switch(tabs, to), do: GenServer.call(tabs, {:switch, to})

  @doc "Moves the active tab one place `:left` or `:right` (not past either end)."
  def move(tabs, direction), do: GenServer.call(tabs, {:move, direction})

  @doc """
  Names a tab: the name shows instead of its program's title. nil or ""
  gives the title back. `tab` may also be one of its panes.
  """
  def rename(tabs, tab, name), do: GenServer.call(tabs, {:rename, tab, name})

  @doc "The session of the active tab's focused pane."
  def active(tabs), do: GenServer.call(tabs, :active)

  @doc "`{[{tab, title}], active_tab}`."
  def list(tabs), do: GenServer.call(tabs, :list)

  @doc """
  Resizes every tab, and makes it the size of tabs opened from now on:
  each pane gets its share. `cell_pixels` is one cell's `{width, height}`
  in pixels, or nil.
  """
  def resize(tabs, cols, rows, cell_pixels \\ nil),
    do: GenServer.call(tabs, {:resize, cols, rows, cell_pixels})

  @doc "Registers a window: it gets the tab list now and on every change."
  def attach_window(tabs, pid), do: GenServer.call(tabs, {:attach_window, pid})

  @impl true
  def init(opts) do
    state = %{
      # sessions are registered with it: see running_sessions/1
      desk: Keyword.get(opts, :desk),
      tabs: [],
      # tab => Guiltty.Layout tree, and the pane with the focus
      layouts: %{},
      focus: %{},
      # session => its program's title
      titles: %{},
      # tab => name given with rename/3, shown instead of the title
      names: %{},
      marks: %{},
      locked: MapSet.new(),
      # the broadcast group: session => {pgid, host}, the foreground
      # process it joined with and where that ssh goes, or :local
      group: %{},
      lost: MapSet.new(),
      check_scheduled: false,
      active: nil,
      size: {Config.get().window.columns, Config.get().window.rows},
      # one cell in pixels, once a window has said (see resize/4)
      cell_pixels: nil,
      windows: MapSet.new(),
      # monitor ref => session id
      monitors: %{},
      session_opts: Keyword.get(opts, :session_opts, []),
      first_cwd: Keyword.get(opts, :cwd)
    }

    {:ok, state, {:continue, :first_tab}}
  end

  @impl true
  def handle_continue(:first_tab, state) do
    case running_sessions(state.desk) do
      [] ->
        case open_tab(state) do
          {:ok, _id, state} -> {:noreply, state}
          {:error, reason} -> {:stop, {:first_tab_failed, reason}, state}
        end

      found ->
        Logger.info("tabs: took back #{length(found)} running sessions")
        {:noreply, Enum.reduce(found, state, &adopt/2)}
    end
  end

  # This desk's sessions that are already running (this process restarted):
  # {id, supervisor pid}, in the order they were opened (ids only grow).
  defp running_sessions(desk) do
    Guiltty.Registry
    |> Registry.select([
      {{{:"$1", :supervisor}, :"$2", :"$3"}, [{:is_integer, :"$1"}, {:"=:=", :"$3", desk}],
       [{{:"$1", :"$2"}}]}
    ])
    |> Enum.sort()
  end

  # Each one a tab of its own: the layout died with the old Tabs.
  defp adopt({id, pid}, state) do
    title = try do: Session.Screen.title(id), catch: (:exit, _ -> "")

    %{
      state
      | tabs: state.tabs ++ [id],
        layouts: Map.put(state.layouts, id, Layout.new(id)),
        focus: Map.put(state.focus, id, id),
        titles: Map.put(state.titles, id, title),
        active: state.active || id
    }
    |> monitor_session(id, pid)
    |> resize_tab(id)
  end

  @impl true
  def handle_call({:new_tab, opts}, _from, state) do
    case open_tab(state, opts) do
      {:ok, id, state} -> {:reply, {:ok, id}, notify_windows(state)}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:split, _dir, _opts}, _from, %{active: nil} = state),
    do: {:reply, {:error, :no_tab}, state}

  def handle_call({:split, dir, opts}, _from, state) when dir in [:right, :down] do
    tab = state.active
    pane = state.focus[tab]
    {_x, _y, w, h} = rects(state, tab) |> elem(0) |> Map.fetch!(pane)

    if (dir == :right and w < 3) or (dir == :down and h < 3) do
      {:reply, {:error, :too_small}, state}
    else
      id = new_id()
      layout = Layout.split(state.layouts[tab], pane, dir, id)
      {rects, _} = Layout.rects(layout, full(state))
      {_x, _y, nw, nh} = rects[id]

      case open_session(state, id, {nw, nh}, opts) do
        {:ok, state} ->
          state = %{
            state
            | layouts: Map.put(state.layouts, tab, layout),
              focus: Map.put(state.focus, tab, id)
          }

          {:reply, {:ok, id}, state |> resize_tab(tab) |> notify_windows()}

        {:error, _} = error ->
          {:reply, error, state}
      end
    end
  end

  def handle_call({:focus, _to}, _from, %{active: nil} = state), do: {:reply, :ok, state}

  def handle_call({:focus, {:pane, id}}, _from, state) do
    tab = state.active

    if Layout.member?(state.layouts[tab], id) and state.focus[tab] != id,
      do: {:reply, :ok, notify_windows(put_in(state.focus[tab], id))},
      else: {:reply, :ok, state}
  end

  def handle_call({:focus, direction}, _from, state) do
    tab = state.active
    {rects, _} = rects(state, tab)

    case Layout.neighbor(rects, state.focus[tab], direction) do
      nil -> {:reply, :ok, state}
      id -> {:reply, :ok, notify_windows(put_in(state.focus[tab], id))}
    end
  end

  def handle_call({:resize_pane, _dir, _cells}, _from, %{active: nil} = state),
    do: {:reply, :ok, state}

  def handle_call({:resize_pane, direction, cells}, _from, state) do
    tab = state.active
    {_x, _y, w, h} = full(state)
    layout = Layout.resize(state.layouts[tab], state.focus[tab], direction, cells, {w, h})

    if layout == state.layouts[tab] do
      {:reply, :ok, state}
    else
      state = put_in(state.layouts[tab], layout)
      {:reply, :ok, state |> resize_tab(tab) |> notify_windows()}
    end
  end

  def handle_call({:toggle_lock, id}, _from, state) do
    case tab_for(state, id) do
      nil ->
        {:reply, :ok, state}

      tab ->
        locked =
          if MapSet.member?(state.locked, tab),
            do: MapSet.delete(state.locked, tab),
            else: MapSet.put(state.locked, tab)

        {:reply, :ok, notify_windows(%{state | locked: locked})}
    end
  end

  def handle_call({:toggle_broadcast, id, programs, opts}, _from, state) do
    case tab_for(state, id) do
      nil -> {:reply, {:error, :no_tab}, state}
      tab -> toggle_broadcast_tab(state, tab, programs, opts)
    end
  end

  def handle_call({:send_input, id, bytes}, _from, state) do
    if Map.has_key?(state.group, id) and map_size(state.group) >= 2 do
      state = check_group(state)

      if MapSet.size(state.lost) == 0 do
        for {member, _} <- state.group, do: Pty.write(member, bytes)
        {:reply, :sent, state}
      else
        {:reply, {:paused, MapSet.to_list(state.lost)}, state}
      end
    else
      Pty.write(id, bytes)
      {:reply, :sent, state}
    end
  end

  def handle_call(:close_unlocked, _from, state) do
    for tab <- state.tabs,
        not MapSet.member?(state.locked, tab),
        id <- Layout.panes(state.layouts[tab]),
        pid = GenServer.whereis(Session.via(id, :supervisor)),
        pid != nil,
        do: DynamicSupervisor.terminate_child(@sessions, pid)

    {:reply, :ok, state}
  end

  def handle_call({:close, id}, _from, state) do
    case GenServer.whereis(Session.via(id, :supervisor)) do
      nil -> {:reply, {:error, :no_such_tab}, state}
      pid -> {:reply, DynamicSupervisor.terminate_child(@sessions, pid), state}
    end
  end

  def handle_call({:switch, to}, _from, state) do
    {:reply, :ok, state |> switch_to(to) |> notify_windows()}
  end

  def handle_call({:move, direction}, _from, state) do
    index = Enum.find_index(state.tabs, &(&1 == state.active))
    target = if direction == :left, do: index - 1, else: index + 1

    if (index && target >= 0) and target < length(state.tabs) do
      tabs = state.tabs |> List.delete_at(index) |> List.insert_at(target, state.active)
      {:reply, :ok, notify_windows(%{state | tabs: tabs})}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:rename, id, name}, _from, state) do
    case tab_for(state, id) do
      nil ->
        {:reply, :ok, state}

      tab ->
        names =
          if name in [nil, ""],
            do: Map.delete(state.names, tab),
            else: Map.put(state.names, tab, name)

        {:reply, :ok, notify_windows(%{state | names: names})}
    end
  end

  def handle_call(:active, _from, state), do: {:reply, focused(state), state}
  def handle_call(:list, _from, state), do: {:reply, {tab_list(state), state.active}, state}

  def handle_call({:resize, cols, rows, cell_pixels}, _from, state) do
    state = %{state | size: {cols, rows}, cell_pixels: cell_pixels}
    state = Enum.reduce(state.tabs, state, &resize_tab(&2, &1))
    {:reply, :ok, notify_windows(state)}
  end

  def handle_call({:attach_window, pid}, _from, state) do
    Process.monitor(pid)
    state = %{state | windows: MapSet.put(state.windows, pid)}
    {:reply, info(state), state}
  end

  @impl true
  def handle_info({:title, id, title}, state) do
    {:noreply, %{state | titles: Map.put(state.titles, id, title)} |> notify_windows()}
  end

  # A pane of a tab you're not looking at printed something, or rang the
  # bell. The active tab needs no mark (and has none to clear, see seen/1).
  def handle_info({:mark, id, mark}, state) do
    tab = tab_of(state, id)

    if tab != nil and tab != state.active and Map.get(state.marks, tab) != :bell,
      do: {:noreply, notify_windows(%{state | marks: Map.put(state.marks, tab, mark)})},
      else: {:noreply, state}
  end

  # A session supervisor went down. If it shut down normally the shell
  # exited (or the pane was closed): the pane is gone. If it crashed, the
  # Sessions supervisor is restarting it; look for the new one shortly.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{monitors: monitors} = state)
      when is_map_key(monitors, ref) do
    {id, monitors} = Map.pop(monitors, ref)
    state = %{state | monitors: monitors}

    if reason in [:normal, :shutdown] or match?({:shutdown, _}, reason) do
      remove_pane(state, id)
    else
      Process.send_after(self(), {:find_session, id, 10}, 50)
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | windows: MapSet.delete(state.windows, pid)}}
  end

  # The group's check, every second while there's a group: a lost pane is
  # marked before you type into it.
  def handle_info(:check_group, state) do
    state = %{state | check_scheduled: false}

    {:noreply,
     if(state.group == %{}, do: state, else: state |> check_group() |> schedule_check())}
  end

  def handle_info({:find_session, id, tries}, state) do
    case GenServer.whereis(Session.via(id, :supervisor)) do
      pid when is_pid(pid) ->
        {:noreply, monitor_session(state, id, pid)}

      nil when tries > 0 ->
        Process.send_after(self(), {:find_session, id, tries - 1}, 50)
        {:noreply, state}

      nil ->
        remove_pane(state, id)
    end
  end

  ## Opening

  defp config_opts(state) do
    config = Config.get()

    shell =
      if config.shell.command,
        do: [shell: config.shell.command, args: config.shell.args],
        else: []

    shell ++ [cwd: start_dir(config.working_directory, state)]
  end

  # :inherit: where the focused pane's shell is now, as a new tab in a
  # browser opens next to the current one. The first tab has none to
  # follow: it starts where `guiltty` was run (`:cwd`), or where guiltty
  # itself was started.
  defp start_dir(:inherit, %{active: nil} = state), do: state.first_cwd

  defp start_dir(:inherit, state),
    do: try(do: Pty.cwd(focused(state)), catch: (:exit, _ -> nil))

  defp start_dir(:home, _state), do: System.user_home()
  defp start_dir(dir, _state), do: dir

  defp open_tab(state, extra \\ []) do
    # Unique across every desk, and increasing: the Registry names sessions
    # by id, and running_sessions/1 sorts by it.
    id = new_id()
    {_x, _y, cols, rows} = full(state)

    case open_session(state, id, {cols, rows}, extra) do
      {:ok, state} ->
        index =
          if state.active, do: Enum.find_index(state.tabs, &(&1 == state.active)) + 1, else: 0

        state = %{
          state
          | tabs: List.insert_at(state.tabs, index, id),
            layouts: Map.put(state.layouts, id, Layout.new(id)),
            focus: Map.put(state.focus, id, id),
            active: id
        }

        {:ok, id, seen(state)}

      {:error, _} = error ->
        error
    end
  end

  defp open_session(state, id, {cols, rows}, extra) do
    # The config says which shell and where; the session_opts given at
    # start (tests use them) win over it, and what the caller asked (an
    # editor instead of the shell) over both.
    opts =
      [id: id, desk: state.desk, cols: cols, rows: rows, owner: self()]
      |> Keyword.put(:cell_pixels, state.cell_pixels)
      |> Keyword.merge(config_opts(state))
      |> Keyword.merge(state.session_opts)
      |> Keyword.merge(extra)

    case DynamicSupervisor.start_child(@sessions, {Session.Supervisor, opts}) do
      {:ok, pid} ->
        {:ok, %{state | titles: Map.put(state.titles, id, "")} |> monitor_session(id, pid)}

      {:error, reason} ->
        Logger.error("tabs: couldn't open a session: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp new_id, do: System.unique_integer([:positive, :monotonic])

  defp monitor_session(state, id, pid) do
    %{state | monitors: Map.put(state.monitors, Process.monitor(pid), id)}
  end

  ## Closing

  defp remove_pane(state, id) do
    state = state |> leave_group(id) |> Map.update!(:titles, &Map.delete(&1, id))

    case tab_of(state, id) do
      nil ->
        {:noreply, state}

      tab ->
        case Layout.remove(state.layouts[tab], id) do
          nil ->
            remove_tab(state, tab)

          layout ->
            # The focus goes to the pane that took the room, if it was
            # this one's.
            focus = state.focus[tab]
            {old_rects, _} = rects(state, tab)
            heir = heir(old_rects, id, layout)

            state = %{
              state
              | layouts: Map.put(state.layouts, tab, layout),
                focus: Map.put(state.focus, tab, if(focus == id, do: heir, else: focus))
            }

            {:noreply, state |> resize_tab(tab) |> notify_windows()}
        end
    end
  end

  # The nearest pane still there, in any direction; the first one if none.
  defp heir(rects, id, layout) do
    left = Layout.panes(layout)

    Enum.find_value([:left, :up, :right, :down], hd(left), fn dir ->
      neighbor = Layout.neighbor(rects, id, dir)
      if neighbor in left, do: neighbor
    end)
  end

  defp remove_tab(state, tab) do
    state = %{state | locked: MapSet.delete(state.locked, tab)}
    index = Enum.find_index(state.tabs, &(&1 == tab))
    tabs = List.delete(state.tabs, tab)

    # The active tab closed: the one to its right takes over, or the last.
    active =
      cond do
        tabs == [] -> nil
        state.active != tab -> state.active
        true -> Enum.at(tabs, min(index, length(tabs) - 1))
      end

    state =
      %{
        state
        | tabs: tabs,
          layouts: Map.delete(state.layouts, tab),
          focus: Map.delete(state.focus, tab),
          names: Map.delete(state.names, tab),
          marks: Map.delete(state.marks, tab),
          active: active
      }
      |> seen()

    if tabs == [] do
      Logger.info("tabs: the last tab closed")
      {:stop, {:shutdown, :last_tab_closed}, state}
    else
      {:noreply, notify_windows(state)}
    end
  end

  ## Moving around

  defp switch_to(%{tabs: []} = state, _to), do: state

  defp switch_to(state, to) do
    index = Enum.find_index(state.tabs, &(&1 == state.active))
    count = length(state.tabs)

    target =
      case to do
        :next -> rem(index + 1, count)
        :prev -> rem(index - 1 + count, count)
        n when is_integer(n) and n >= 0 and n < count -> n
        _ -> index
      end

    seen(%{state | active: Enum.at(state.tabs, target)})
  end

  # The active tab is the one you're looking at: nothing new in it.
  defp seen(state), do: %{state | marks: Map.delete(state.marks, state.active)}

  ## Sizes

  defp full(%{size: {cols, rows}}), do: {0, 0, cols, rows}
  defp rects(state, tab), do: Layout.rects(state.layouts[tab], full(state))

  # Every pane of the tab gets the size of its place in the layout.
  defp resize_tab(state, tab) do
    {rects, _} = rects(state, tab)

    for {id, {_x, _y, w, h}} <- rects,
        do: try(do: Session.resize(id, w, h, state.cell_pixels), catch: (:exit, _ -> :ok))

    state
  end

  ## Who's where

  defp focused(%{active: nil}), do: nil
  defp focused(state), do: state.focus[state.active]

  defp tab_of(state, id),
    do: Enum.find(state.tabs, fn tab -> Layout.member?(state.layouts[tab], id) end)

  # A tab's id, or one of its panes'.
  defp tab_for(state, id), do: if(id in state.tabs, do: id, else: tab_of(state, id))

  ## The broadcast group

  defp toggle_broadcast_tab(state, tab, programs, opts) do
    members = Layout.panes(state.layouts[tab])

    if Enum.any?(members, &Map.has_key?(state.group, &1)) do
      state = Enum.reduce(members, state, &leave_group(&2, &1))
      {:reply, {:ok, :left}, notify_windows(state)}
    else
      # Each pane's foreground: an allowed program joins checked, the
      # others only as local panes, and only when asked.
      joining =
        for id <- members do
          case safe_foreground(id) do
            {pgid, program} when is_binary(program) ->
              if program in programs and !opts[:local],
                do: {id, {:remote, pgid}},
                else: {id, {:other, program}}

            nil ->
              {id, {:other, "nothing"}}
          end
        end

      others = for {_id, {:other, program}} <- joining, do: program

      if others != [] and !opts[:local] do
        {:reply, {:error, {:not_allowed, hd(others)}}, state}
      else
        group =
          Enum.reduce(joining, state.group, fn
            {id, {:remote, pgid}}, group -> Map.put(group, id, {pgid, host_of(pgid)})
            {id, {:other, _}}, group -> Map.put(group, id, :local)
          end)

        state = %{state | group: group}

        state =
          if Enum.any?(joining, &match?({_, {:remote, _}}, &1)),
            do: schedule_check(state),
            else: state

        {:reply, {:ok, :joined}, notify_windows(state)}
      end
    end
  end

  defp leave_group(state, id),
    do: %{state | group: Map.delete(state.group, id), lost: MapSet.delete(state.lost, id)}

  defp schedule_check(%{check_scheduled: true} = state), do: state

  defp schedule_check(state) do
    Process.send_after(self(), :check_group, 1_000)
    %{state | check_scheduled: true}
  end

  # Which group panes no longer run what they joined with. Tells windows
  # when that changes.
  defp check_group(state) do
    # Local panes have no connection to lose: only remote ones are checked.
    lost =
      for {id, {pgid, _host}} <- state.group,
          not match?({^pgid, _}, safe_foreground(id)),
          into: MapSet.new(),
          do: id

    if lost == state.lost, do: state, else: notify_windows(%{state | lost: lost})
  end

  defp safe_foreground(id), do: try(do: Pty.foreground(id), catch: (:exit, _ -> nil))

  # Where an ssh goes, for messages: its destination, from its command line
  # (`ssh -p 2222 admin@web-02` is "web-02"). nil when it isn't one.
  @ssh_options_with_values ~w(-b -c -D -E -e -F -I -i -J -L -l -m -O -o -p -Q -R -S -W -w -B)
  defp host_of(pgid) do
    case File.read("/proc/#{pgid}/cmdline") do
      {:ok, cmdline} -> cmdline |> String.split(<<0>>, trim: true) |> ssh_host()
      _ -> nil
    end
  end

  @doc false
  # The host an ssh command line goes to: ["ssh", "-p", "2222",
  # "admin@web-02", "uptime"] is "web-02".
  def ssh_host([_program | args]) do
    case destination(args) do
      nil -> nil
      dest -> dest |> String.split("@") |> List.last()
    end
  end

  def ssh_host(_), do: nil

  defp destination([option, _value | rest]) when option in @ssh_options_with_values,
    do: destination(rest)

  defp destination(["-" <> _ | rest]), do: destination(rest)
  defp destination([dest | _]), do: dest
  defp destination([]), do: nil

  ## Telling windows

  defp tab_list(state) do
    Enum.map(state.tabs, fn tab ->
      {tab, state.names[tab] || Map.get(state.titles, state.focus[tab], "")}
    end)
  end

  defp info(state) do
    panes =
      case state.active do
        nil ->
          nil

        tab ->
          {rects, separators} = rects(state, tab)
          %{focus: state.focus[tab], rects: rects, separators: separators}
      end

    %{
      list: tab_list(state),
      active: state.active,
      panes: panes,
      members: Map.new(state.tabs, &{&1, Layout.panes(state.layouts[&1])}),
      size: state.size,
      locked: state.locked,
      group:
        Map.new(state.group, fn
          {id, :local} -> {id, :local}
          {id, {_pgid, host}} -> {id, host}
        end),
      lost: state.lost,
      marks: state.marks
    }
  end

  defp notify_windows(state) do
    message = {:tabs, info(state)}
    Enum.each(state.windows, &send(&1, message))
    state
  end
end

defmodule Guiltty.Tabs do
  @moduledoc """
  One window's tabs: which sessions it has, in which order, which one is
  active, and their titles. Every window has its own (`Guiltty.Desk`), so
  windows are independent: their tabs, locked tabs and broadcast groups
  never mix. Every function takes the desk's Tabs (`Guiltty.Desk.tabs/1`,
  or a pid).

  Each tab is a session (`Guiltty.Session.Supervisor`) started under the
  `Guiltty.Sessions` DynamicSupervisor, with an integer id unique across
  all desks. The session is registered with its desk's id, so if this
  process crashes, the new one takes back its own sessions, and only those.

  A window registers with `attach_window/2` and then gets `{:tabs, info}`
  whenever something changes. `info` is a map:

    * `:list` - `[{id, title}]`, in order
    * `:active` - the active tab's id
    * `:locked` - the tabs that stay when the window closes (`toggle_lock/1`)
    * `:group` - the broadcast group, `%{id => host}`, or `:local` for a
      local tab (`toggle_broadcast/3`)
    * `:lost` - group tabs whose connection is gone (broadcast is paused)

  ## Broadcast

  Typing in one tab of the broadcast group goes to every tab in it, to do
  the same thing on several servers at once. A tab joins only while it's
  running one of the allowed programs (ssh, by default), and joining
  records that program's process. Before any keystroke goes out, every
  tab is checked: is that same process still in its terminal's
  foreground? If an ssh has exited, its tab's foreground is the local
  shell again, and the keystroke goes *nowhere*: the broadcast pauses
  until the lost tab leaves the group (or closes). The same check runs
  every second, so the tab is marked before you type.

  Your own machine can be in the group too, as a *local* tab: joined on
  purpose (`toggle_broadcast(id, programs, local: true)`), and not
  checked, since there's no connection to lose. (Checking would not work
  either: in a local tab every command you run takes the foreground.)

  A tab ends when its shell exits (or `close/2`). When the last one ends,
  this process stops; it's significant in its desk, so the desk stops with
  it (and guiltty, if it was the last desk: `Guiltty.Lifeline`).
  """

  use GenServer, restart: :transient

  require Logger

  alias Guiltty.{Config, Session}
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

  @doc "Opens a new tab after the active one and makes it active. Returns its id."
  def new_tab(tabs), do: GenServer.call(tabs, :new_tab)

  @doc "Closes a tab: its shell gets SIGHUP."
  def close(tabs, id), do: GenServer.call(tabs, {:close, id})

  @doc """
  Locks or unlocks a tab. Closing the window closes every tab but the
  locked ones; those keep running, and the window comes back with them.
  """
  def toggle_lock(tabs, id), do: GenServer.call(tabs, {:toggle_lock, id})

  @doc """
  Closes every tab that isn't locked (each shell gets SIGHUP). If none is
  locked, the last one ending stops Tabs, and its desk with it.
  """
  def close_unlocked(tabs), do: GenServer.call(tabs, :close_unlocked)

  @doc """
  Puts a tab in the broadcast group, or takes it out. To join, its
  foreground program must be one of `programs`; with `local: true` it
  joins as a local tab whatever it runs. Returns `{:ok, :joined}`,
  `{:ok, :left}` or `{:error, {:not_allowed, program}}`.
  """
  def toggle_broadcast(tabs, id, programs, opts \\ []),
    do: GenServer.call(tabs, {:toggle_broadcast, id, programs, opts})

  @doc """
  Sends typed input from tab `id`. In a broadcast group of two or more, it
  goes to every tab in the group, but only if every one still runs what it
  joined with; otherwise to nobody, and `{:paused, lost_ids}` comes back.
  Outside a group it goes to that tab alone.
  """
  def send_input(tabs, id, bytes), do: GenServer.call(tabs, {:send_input, id, bytes})

  @doc "Switches to `:next`, `:prev`, or the tab at a 0-based index."
  def switch(tabs, to), do: GenServer.call(tabs, {:switch, to})

  @doc "The active tab's session id."
  def active(tabs), do: GenServer.call(tabs, :active)

  @doc "`{[{id, title}], active_id}`."
  def list(tabs), do: GenServer.call(tabs, :list)

  @doc "Resizes every tab, and makes it the size of tabs opened from now on."
  def resize(tabs, cols, rows), do: GenServer.call(tabs, {:resize, cols, rows})

  @doc "Registers a window: it gets the tab list now and on every change."
  def attach_window(tabs, pid), do: GenServer.call(tabs, {:attach_window, pid})

  @impl true
  def init(opts) do
    state = %{
      # sessions are registered with it: see running_sessions/1
      desk: Keyword.get(opts, :desk),
      tabs: [],
      titles: %{},
      locked: MapSet.new(),
      # the broadcast group: id => {pgid, host}, the foreground process it
      # joined with and where that ssh goes
      group: %{},
      lost: MapSet.new(),
      check_scheduled: false,
      active: nil,
      size: {Config.get().window.columns, Config.get().window.rows},
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

  defp adopt({id, pid}, state) do
    title = try do: Session.Screen.title(id), catch: (:exit, _ -> "")

    %{
      state
      | tabs: state.tabs ++ [id],
        titles: Map.put(state.titles, id, title),
        active: state.active || id
    }
    |> monitor_session(id, pid)
  end

  @impl true
  def handle_call(:new_tab, _from, state) do
    case open_tab(state) do
      {:ok, id, state} -> {:reply, {:ok, id}, notify_windows(state)}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:toggle_lock, id}, _from, state) do
    locked =
      if MapSet.member?(state.locked, id),
        do: MapSet.delete(state.locked, id),
        else: MapSet.put(state.locked, id)

    {:reply, :ok, notify_windows(%{state | locked: locked})}
  end

  def handle_call({:toggle_broadcast, id, programs, opts}, _from, state) do
    cond do
      Map.has_key?(state.group, id) ->
        {:reply, {:ok, :left}, state |> leave_group(id) |> notify_windows()}

      opts[:local] ->
        state = %{state | group: Map.put(state.group, id, :local)}
        {:reply, {:ok, :joined}, notify_windows(state)}

      true ->
        case safe_foreground(id) do
          {pgid, program} when is_binary(program) ->
            if program in programs do
              group = Map.put(state.group, id, {pgid, host_of(pgid)})
              state = schedule_check(%{state | group: group})
              {:reply, {:ok, :joined}, notify_windows(state)}
            else
              {:reply, {:error, {:not_allowed, program}}, state}
            end

          nil ->
            {:reply, {:error, {:not_allowed, "nothing"}}, state}
        end
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
    for id <- state.tabs,
        not MapSet.member?(state.locked, id),
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

  def handle_call(:active, _from, state), do: {:reply, state.active, state}
  def handle_call(:list, _from, state), do: {:reply, {tab_list(state), state.active}, state}

  def handle_call({:resize, cols, rows}, _from, state) do
    for id <- state.tabs, do: Session.resize(id, cols, rows)
    {:reply, :ok, %{state | size: {cols, rows}}}
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

  # A session supervisor went down. If it shut down normally the shell
  # exited (or the tab was closed): the tab is gone. If it crashed, the
  # Sessions supervisor is restarting it; look for the new one shortly.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{monitors: monitors} = state)
      when is_map_key(monitors, ref) do
    {id, monitors} = Map.pop(monitors, ref)
    state = %{state | monitors: monitors}

    if reason in [:normal, :shutdown] or match?({:shutdown, _}, reason) do
      remove_tab(state, id)
    else
      Process.send_after(self(), {:find_session, id, 10}, 50)
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | windows: MapSet.delete(state.windows, pid)}}
  end

  # The group's check, every second while there's a group: a lost tab is
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
        remove_tab(state, id)
    end
  end

  defp config_opts(state) do
    config = Config.get()

    shell =
      if config.shell.command,
        do: [shell: config.shell.command, args: config.shell.args],
        else: []

    shell ++ [cwd: start_dir(config.working_directory, state)]
  end

  # :inherit: where the active tab's shell is now, as a new tab in a
  # browser opens next to the current one. The first tab has none to
  # follow: it starts where `guiltty` was run (`:cwd`), or where guiltty
  # itself was started.
  defp start_dir(:inherit, %{active: nil} = state), do: state.first_cwd

  defp start_dir(:inherit, %{active: active}),
    do: try(do: Pty.cwd(active), catch: (:exit, _ -> nil))

  defp start_dir(:home, _state), do: System.user_home()
  defp start_dir(dir, _state), do: dir

  defp open_tab(state) do
    # Unique across every desk, and increasing: the Registry names sessions
    # by id, and running_sessions/1 sorts by it.
    id = System.unique_integer([:positive, :monotonic])
    {cols, rows} = state.size
    # The config says which shell and where; the session_opts given at
    # start (tests use them) win over it.
    opts =
      [id: id, desk: state.desk, cols: cols, rows: rows, owner: self()]
      |> Keyword.merge(config_opts(state))
      |> Keyword.merge(state.session_opts)

    case DynamicSupervisor.start_child(@sessions, {Session.Supervisor, opts}) do
      {:ok, pid} ->
        index =
          if state.active, do: Enum.find_index(state.tabs, &(&1 == state.active)) + 1, else: 0

        state = %{
          state
          | tabs: List.insert_at(state.tabs, index, id),
            titles: Map.put(state.titles, id, ""),
            active: id
        }

        {:ok, id, monitor_session(state, id, pid)}

      {:error, reason} ->
        Logger.error("tabs: couldn't open a tab: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp monitor_session(state, id, pid) do
    %{state | monitors: Map.put(state.monitors, Process.monitor(pid), id)}
  end

  defp remove_tab(state, id) do
    state = %{state | locked: MapSet.delete(state.locked, id)} |> leave_group(id)
    index = Enum.find_index(state.tabs, &(&1 == id))
    tabs = List.delete(state.tabs, id)

    # The active tab closed: the one to its right takes over, or the last.
    active =
      cond do
        tabs == [] -> nil
        state.active != id -> state.active
        true -> Enum.at(tabs, min(index, length(tabs) - 1))
      end

    state = %{state | tabs: tabs, titles: Map.delete(state.titles, id), active: active}

    if tabs == [] do
      Logger.info("tabs: the last tab closed")
      {:stop, {:shutdown, :last_tab_closed}, state}
    else
      {:noreply, notify_windows(state)}
    end
  end

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

    %{state | active: Enum.at(state.tabs, target)}
  end

  ## The broadcast group

  defp leave_group(state, id),
    do: %{state | group: Map.delete(state.group, id), lost: MapSet.delete(state.lost, id)}

  defp schedule_check(%{check_scheduled: true} = state), do: state

  defp schedule_check(state) do
    Process.send_after(self(), :check_group, 1_000)
    %{state | check_scheduled: true}
  end

  # Which group tabs no longer run what they joined with. Tells windows
  # when that changes.
  defp check_group(state) do
    # Local tabs have no connection to lose: only remote ones are checked.
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

  defp tab_list(state), do: Enum.map(state.tabs, &{&1, Map.get(state.titles, &1, "")})

  defp info(state) do
    %{
      list: tab_list(state),
      active: state.active,
      locked: state.locked,
      group:
        Map.new(state.group, fn
          {id, :local} -> {id, :local}
          {id, {_pgid, host}} -> {id, host}
        end),
      lost: state.lost
    }
  end

  defp notify_windows(state) do
    message = {:tabs, info(state)}
    Enum.each(state.windows, &send(&1, message))
    state
  end
end

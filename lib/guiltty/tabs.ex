defmodule Guiltty.Tabs do
  @moduledoc """
  The tabs: which sessions exist, in which order, which one is active, and
  their titles.

  Each tab is a session (`Guiltty.Session.Supervisor`) started under the
  `Guiltty.Sessions` DynamicSupervisor, with an integer id. The tabs don't
  belong to a window: closing the window leaves them running, and the next
  window shows them again. That's detach and reattach.

  A window registers with `attach_window/1` and then gets
  `{:tabs, [{id, title}], active_id}` whenever something changes.

  A tab ends when its shell exits (or `close/1`). When the last one ends,
  this process stops; it's significant in the application supervisor, so
  guiltty stops with it.

  If this process crashes, the sessions keep running: the new one finds
  them in the Registry and takes them back as tabs.
  """

  use GenServer, restart: :transient

  require Logger

  alias Guiltty.{Config, Session}
  alias Guiltty.Session.Pty

  @sessions Guiltty.Sessions

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Opens a new tab after the active one and makes it active. Returns its id."
  def new_tab, do: GenServer.call(__MODULE__, :new_tab)

  @doc "Closes a tab: its shell gets SIGHUP."
  def close(id), do: GenServer.call(__MODULE__, {:close, id})

  @doc "Switches to `:next`, `:prev`, or the tab at a 0-based index."
  def switch(to), do: GenServer.call(__MODULE__, {:switch, to})

  @doc "The active tab's session id."
  def active, do: GenServer.call(__MODULE__, :active)

  @doc "`{[{id, title}], active_id}`."
  def list, do: GenServer.call(__MODULE__, :list)

  @doc "Resizes every tab, and makes it the size of tabs opened from now on."
  def resize(cols, rows), do: GenServer.call(__MODULE__, {:resize, cols, rows})

  @doc "Registers a window: it gets the tab list now and on every change."
  def attach_window(pid), do: GenServer.call(__MODULE__, {:attach_window, pid})

  @impl true
  def init(opts) do
    state = %{
      tabs: [],
      titles: %{},
      active: nil,
      next_id: 1,
      size: {Config.get().window.columns, Config.get().window.rows},
      windows: MapSet.new(),
      # monitor ref => session id
      monitors: %{},
      session_opts: Keyword.get(opts, :session_opts, [])
    }

    {:ok, state, {:continue, :first_tab}}
  end

  @impl true
  def handle_continue(:first_tab, state) do
    case running_sessions() do
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

  # Sessions already running (this process restarted): {id, supervisor pid}.
  defp running_sessions do
    Guiltty.Registry
    |> Registry.select([
      {{{:"$1", :supervisor}, :"$2", :_}, [{:is_integer, :"$1"}], [{{:"$1", :"$2"}}]}
    ])
    |> Enum.sort()
  end

  defp adopt({id, pid}, state) do
    title = try do: Session.Screen.title(id), catch: (:exit, _ -> "")

    %{
      state
      | tabs: state.tabs ++ [id],
        titles: Map.put(state.titles, id, title),
        active: state.active || id,
        next_id: max(state.next_id, id + 1)
    }
    |> monitor_session(id, pid)
  end

  @impl true
  def handle_call(:new_tab, _from, state) do
    case open_tab(state) do
      {:ok, id, state} -> {:reply, {:ok, id}, broadcast(state)}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:close, id}, _from, state) do
    case GenServer.whereis(Session.via(id, :supervisor)) do
      nil -> {:reply, {:error, :no_such_tab}, state}
      pid -> {:reply, DynamicSupervisor.terminate_child(@sessions, pid), state}
    end
  end

  def handle_call({:switch, to}, _from, state) do
    {:reply, :ok, state |> switch_to(to) |> broadcast()}
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
    {:reply, {tab_list(state), state.active}, state}
  end

  @impl true
  def handle_info({:title, id, title}, state) do
    {:noreply, %{state | titles: Map.put(state.titles, id, title)} |> broadcast()}
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

    shell ++ [cwd: start_dir(config.working_directory, state.active)]
  end

  # :inherit: where the active tab's shell is now, as a new tab in a
  # browser opens next to the current one. The first tab has none to
  # follow, and starts where guiltty was started.
  defp start_dir(:inherit, nil), do: nil
  defp start_dir(:inherit, active), do: try(do: Pty.cwd(active), catch: (:exit, _ -> nil))
  defp start_dir(:home, _active), do: System.user_home()
  defp start_dir(dir, _active), do: dir

  defp open_tab(state) do
    id = state.next_id
    {cols, rows} = state.size
    # The config says which shell and where; the session_opts given at
    # start (tests use them) win over it.
    opts =
      [id: id, cols: cols, rows: rows, owner: self()]
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
            active: id,
            next_id: id + 1
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
      {:noreply, broadcast(state)}
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

  defp tab_list(state), do: Enum.map(state.tabs, &{&1, Map.get(state.titles, &1, "")})

  defp broadcast(state) do
    message = {:tabs, tab_list(state), state.active}
    Enum.each(state.windows, &send(&1, message))
    state
  end
end

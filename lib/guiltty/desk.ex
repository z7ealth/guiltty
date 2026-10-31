defmodule Guiltty.Desk do
  @moduledoc """
  One window and its tabs, independent of every other window: its own
  `Guiltty.Tabs` (the tab list, the active tab, the locked tabs, the
  broadcast group) and its own `Guiltty.Window` (the renderer).

      Desk (rest_for_one, auto_shutdown: any_significant)
      ├── Tabs     significant: when its last tab closes, the desk ends
      └── Window

  The Window comes after the Tabs it shows, so if the Tabs restarts, the
  Window restarts with it and attaches to the new one. A Window that
  crashes (its renderer did) restarts alone and attaches again.

  Closing the window closes the desk's unlocked tabs. With none locked, the
  last one closing ends the Tabs, and so the desk. With some locked, the
  desk stays, *windowless*, its tabs running, until `reopen/2` gives it a
  window again (the next `guiltty`). Desks live under `Guiltty.Desks`;
  `Guiltty.Lifeline` stops guiltty when the last is gone.
  """

  use Supervisor, restart: :transient

  alias Guiltty.{Tabs, Window}

  @doc """
  Options: `:desk` (its id, required), `:window` (options for the
  `Guiltty.Window`) and `:session_opts` (for every tab's session; tests use
  them).
  """
  def start_link(opts) do
    desk = Keyword.fetch!(opts, :desk)
    Supervisor.start_link(__MODULE__, opts, name: name(desk))
  end

  @doc "The desk's registered name."
  def name(desk), do: {:via, Registry, {Guiltty.Registry, {:desk, desk}}}

  @doc "The desk's Tabs, for the `Guiltty.Tabs` functions."
  def tabs(desk), do: {:via, Registry, {Guiltty.Registry, {:desk, desk, :tabs}}}

  @doc "The ids of the running desks."
  def all do
    Registry.select(Guiltty.Registry, [{{{:desk, :"$1"}, :_, :_}, [], [:"$1"]}])
  end

  @doc """
  Whether the desk has no window: it was closed with locked tabs, which
  keep running.
  """
  def windowless?(desk) do
    Supervisor.which_children(name(desk))
    |> Enum.any?(&match?({Window, :undefined, _, _}, &1))
  catch
    :exit, _ -> false
  end

  @doc """
  Gives a windowless desk a new window, with these `Guiltty.Window`
  options (the display it should open on). Its tabs show again as they
  were left.
  """
  def reopen(desk, window_opts) do
    sup = name(desk)

    # The old Window's child spec has the old options (another display,
    # maybe): replace it rather than restart it.
    with :ok <- Supervisor.delete_child(sup, Window),
         {:ok, _pid} <-
           Supervisor.start_child(sup, {Window, Keyword.put(window_opts, :tabs, tabs(desk))}) do
      :ok
    end
  end

  @impl true
  def init(opts) do
    desk = Keyword.fetch!(opts, :desk)
    tabs_opts = [desk: desk, name: tabs(desk), session_opts: Keyword.get(opts, :session_opts, [])]
    window_opts = Keyword.merge(Keyword.get(opts, :window, []), tabs: tabs(desk))

    children = [
      Supervisor.child_spec({Tabs, tabs_opts}, significant: true),
      {Window, window_opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one, auto_shutdown: :any_significant)
  end
end

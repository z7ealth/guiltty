defmodule Guiltty.Window do
  @moduledoc """
  Owns the renderer port: shows the active tab, turns the renderer's events
  into bytes for that tab's shell, and handles guiltty's own keys.

  The renderer is a separate OS process, so if it crashes only this process
  notices; the supervisor starts a new Window, which starts a new renderer
  and redraws from the Screen. When the user closes the window the renderer
  exits with status 0 and this process stops normally: the tabs keep
  running, and the next window shows them again (detach and reattach).

  ## Frames

  The Window doesn't forward every screen change. It views the active tab's
  Screen, which says `{:screen_dirty, id}` when something changed; the
  Window takes one combined update (`Screen.take_update/1`), sends it, and
  takes the next only after the renderer reports it drew a frame. So the
  renderer gets at most one update per frame, however fast a program
  prints. Frame times are emitted as `[:guiltty, :renderer, :frame]`
  (`%{duration: microseconds}`).
  """

  use GenServer, restart: :transient

  require Logger

  alias Guiltty.{Config, Keymap, Session, Tabs}
  alias Guiltty.Session.{Pty, Screen}
  alias Guiltty.Window.Protocol

  @hello_timeout 5_000
  @resubscribe_ms 50
  @halo_color {0x81, 0xA2, 0xBE}
  @halo_ms 400
  @default_input %{
    cursor_keys: :normal,
    keypad: :numeric,
    bracketed_paste: false,
    mouse: nil,
    mouse_sgr: false
  }

  @doc """
  Options: `:renderer` (a binary in priv/), `:env` (extra environment for
  the renderer, as `[{charlist, charlist}]`) and `:name` (defaults to
  `Guiltty.Window`; `false` for none).
  """
  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      false -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    renderer = Keyword.get(opts, :renderer, Application.get_env(:guiltty, :renderer))
    path = Path.join(:code.priv_dir(:guiltty), renderer)

    port =
      Port.open({:spawn_executable, path}, [
        :binary,
        :exit_status,
        :use_stdio,
        packet: 4,
        env: Keyword.get(opts, :env, [])
      ])

    config = Config.get()
    if Process.whereis(Config), do: Config.subscribe(self())

    # Flash the border when a parser comes back from a crash.
    handler = {__MODULE__, self()}

    :telemetry.attach(
      handler,
      [:guiltty, :session, :parser_restarted],
      &__MODULE__.forward_restart/4,
      self()
    )

    state = %{
      port: port,
      handler: handler,
      ready: false,
      # the session being shown, and a monitor on its Screen
      active: nil,
      screen_ref: nil,
      tabs: [],
      # one update in flight to the renderer at a time
      awaiting_frame: false,
      pending: false,
      size: nil,
      input: @default_input,
      title: nil,
      config: config,
      bindings: parse_bindings(config.keys)
    }

    {:ok, state, @hello_timeout}
  end

  @doc false
  def forward_restart(_event, _measurements, %{session: id}, pid),
    do: send(pid, {:parser_restarted, id})

  ## Renderer messages

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    case Protocol.decode(data) do
      {:ok, event} -> handle_event(event, state)
      {:error, reason} -> {:stop, reason, state}
    end
  end

  # The renderer exits 0 when the user closes the window.
  def handle_info({port, {:exit_status, 0}}, %{port: port} = state) do
    {:stop, {:shutdown, :window_closed}, %{state | port: nil}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:stop, {:renderer_exited, status}, %{state | port: nil}}
  end

  def handle_info(:timeout, state), do: {:stop, :no_hello_from_renderer, state}

  ## Screen and tabs

  def handle_info({:screen_dirty, id}, %{active: id} = state), do: {:noreply, pull(state)}
  def handle_info({:screen_dirty, _other}, state), do: {:noreply, state}

  def handle_info({:tabs, tabs, active}, state), do: {:noreply, show_tabs(state, tabs, active)}

  # The active Screen restarted (it crashed, or its session did). The new
  # one doesn't know about us, so view it again.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{screen_ref: ref} = state) do
    {:noreply, view(%{state | screen_ref: nil, awaiting_frame: false}, state.active)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}
  def handle_info({:view, id}, %{active: id} = state), do: {:noreply, view(state, id)}
  def handle_info({:view, _old}, state), do: {:noreply, state}

  def handle_info({:parser_restarted, _id}, state) do
    send_port(state, Protocol.halo(@halo_color, @halo_ms))
    {:noreply, state}
  end

  def handle_info({:config, config}, state), do: {:noreply, apply_config(state, config)}

  def handle_info(:raise, state) do
    send_port(state, Protocol.raise_window())
    {:noreply, state}
  end

  ## Renderer events

  defp handle_event({:hello, version, backend}, state) do
    if version == Protocol.version() do
      Logger.debug("window: renderer #{backend} speaks protocol #{version}")
      {tabs, active} = Tabs.attach_window(self())
      {cols, rows} = Session.size(active)
      send_port(state, Protocol.setup(cols, rows, state.config.theme, state.config.font))
      {:noreply, show_tabs(%{state | ready: true, size: {cols, rows}}, tabs, active)}
    else
      {:stop, {:protocol_mismatch, renderer: version, window: Protocol.version()}, state}
    end
  end

  defp handle_event({:frame, us}, state) do
    :telemetry.execute([:guiltty, :renderer, :frame], %{duration: us}, %{})
    state = %{state | awaiting_frame: false}
    {:noreply, if(state.pending, do: pull(state), else: state)}
  end

  # The user resized the window and the renderer worked out the new grid.
  defp handle_event({:resize, cols, rows}, state) do
    Tabs.resize(cols, rows)
    {:noreply, %{state | size: {cols, rows}}}
  end

  defp handle_event({:tab_click, index}, state) do
    Tabs.switch(index)
    {:noreply, state}
  end

  defp handle_event({:paste, text}, state) do
    write(state, Keymap.paste(text, state.input))
    {:noreply, state}
  end

  defp handle_event({:mouse, _, _, _, _, _} = event, state) do
    write(state, Keymap.mouse(event, state.input))
    {:noreply, state}
  end

  defp handle_event({:key, _, _} = event, state) do
    case Enum.find(state.bindings, fn {_action, binding} -> Keymap.matches?(event, binding) end) do
      {action, _binding} -> {:noreply, run(action, state)}
      nil -> type(event, state)
    end
  end

  defp handle_event({:text, _} = event, state), do: type(event, state)

  defp type(event, state) do
    write(state, Keymap.to_bytes(event, state.input))
    {:noreply, state}
  end

  defp write(_state, nil), do: :ok
  defp write(%{active: nil}, _bytes), do: :ok
  defp write(state, bytes), do: Pty.write(state.active, bytes)

  ## guiltty's own keys

  defp run(:new_tab, state) do
    Tabs.new_tab()
    state
  end

  defp run(:close_tab, state) do
    if state.active, do: Tabs.close(state.active)
    state
  end

  defp run(:next_tab, state), do: switch(state, :next)
  defp run(:prev_tab, state), do: switch(state, :prev)
  defp run({:go_to_tab, n}, state), do: switch(state, n)

  defp run(_unknown, state), do: state

  defp switch(state, to) do
    Tabs.switch(to)
    state
  end

  defp parse_bindings(keys) do
    go_to = for n <- 1..9, do: {{:go_to_tab, n - 1}, ["ctrl+shift+#{n}"]}

    for {action, names} <- Map.to_list(keys) ++ go_to,
        name <- names,
        {:ok, binding} <- [Keymap.parse_key(name)],
        do: {action, binding}
  end

  ## Showing a tab

  defp show_tabs(state, tabs, active) do
    titles = Enum.map(tabs, fn {_id, title} -> if title == "", do: "shell", else: title end)
    index = Enum.find_index(tabs, fn {id, _} -> id == active end) || 0
    send_port(state, Protocol.tabs(titles, index))
    state = %{state | tabs: tabs}
    if active != state.active, do: switch_view(state, active), else: state
  end

  defp switch_view(state, id) do
    if state.active, do: catch_exit(fn -> Screen.unsubscribe(state.active, self()) end)
    if state.screen_ref, do: Process.demonitor(state.screen_ref, [:flush])
    view(%{state | active: id, screen_ref: nil, pending: false, title: nil}, id)
  end

  # View the session's Screen and monitor it. It answers with
  # {:screen_dirty, id}; if it isn't running right now (mid-restart), try
  # again shortly.
  defp view(state, nil), do: state

  defp view(state, id) do
    with pid when is_pid(pid) <- GenServer.whereis(Session.via(id, :screen)),
         ref = Process.monitor(pid),
         :ok <- catch_exit(fn -> Screen.subscribe(id, self()) end) do
      %{state | screen_ref: ref}
    else
      _ ->
        Process.send_after(self(), {:view, id}, @resubscribe_ms)
        state
    end
  end

  # Take the next update, unless the renderer is still drawing the last one.
  defp pull(%{awaiting_frame: true} = state), do: %{state | pending: true}
  defp pull(%{active: nil} = state), do: state

  defp pull(state) do
    case catch_exit(fn -> Screen.take_update(state.active) end) do
      %{} = update ->
        send_port(state, Protocol.rows(update))

        if update.title != state.title,
          do: send_port(state, Protocol.title(window_title(update.title)))

        %{state | awaiting_frame: true, pending: false, input: update.input, title: update.title}

      _gone ->
        state
    end
  end

  defp window_title(""), do: "guiltty"
  defp window_title(title), do: title

  ## Config

  defp apply_config(state, config) do
    if config.theme != state.config.theme do
      send_port(state, Protocol.theme(config.theme))
      # The renderer resolved every cell with the old theme: send them all again.
      if state.active, do: catch_exit(fn -> Screen.subscribe(state.active, self()) end)
    end

    if config.font != state.config.font, do: send_port(state, Protocol.font(config.font))
    %{state | config: config, bindings: parse_bindings(config.keys)}
  end

  defp send_port(%{port: port}, message) when is_port(port), do: Port.command(port, message)
  defp send_port(_state, _message), do: :ok

  defp catch_exit(fun) do
    fun.()
  catch
    :exit, _ -> :exit
  end

  @impl true
  def terminate(_reason, state) do
    :telemetry.detach(state.handler)
    # Closing stdin tells the renderer to quit.
    if is_port(state.port) and Port.info(state.port), do: Port.close(state.port)
    :ok
  end
end

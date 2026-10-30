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

  ## The mouse

  Mouse events go to the program when it asked for them (mouse reporting
  modes), unless Shift is held. Otherwise guiltty uses them: the left
  button selects (double click: words, triple: lines) and copies the
  selection to the primary selection, the middle button pastes it, and the
  wheel scrolls back (or, on the alternate screen, sends arrow keys, so
  `less` and `man` scroll).

  ## Search

  The search key (Ctrl+Shift+F) starts a search: typing goes to the query
  instead of the program, Enter finds the next older match, Shift+Enter
  the next newer one, and Escape ends it. The query shows at the right of
  the tab bar.
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
  @min_font 6
  @max_font 96
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
      bindings: parse_bindings(config.keys),
      # font size steps added by zooming
      zoom: 0,
      # the left button is down and selecting
      selecting: false,
      # search mode: %{query: binary, found: boolean}
      search: nil,
      alt_screen: false,
      # the view's scroll as of the last update, and whether this window
      # moved it since (the update saying so may not have arrived yet)
      scroll: 0,
      view_moved: false,
      scrollback: 0,
      status: ""
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
      setup = Protocol.setup(cols, rows, state.config.theme, font(state), options(state.config))
      send_port(state, setup)
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
    {:noreply, write(state, Keymap.paste(text, state.input))}
  end

  defp handle_event({:mouse, _kind, _button, _col, _row, mods, _clicks} = event, state) do
    if state.input.mouse != nil and not Keymap.shift?(mods),
      do: {:noreply, write(state, Keymap.mouse(event, state.input))},
      else: {:noreply, local_mouse(event, state)}
  end

  defp handle_event({:key, _, _} = event, state) do
    case Enum.find(state.bindings, fn {_action, binding} -> Keymap.matches?(event, binding) end) do
      {action, _binding} -> {:noreply, run(action, state)}
      nil when state.search != nil -> {:noreply, search_key(event, state)}
      nil -> type(event, state)
    end
  end

  defp handle_event({:text, text}, %{search: %{}} = state),
    do: {:noreply, search_for(state, state.search.query <> text, :start)}

  defp handle_event({:text, _} = event, state), do: type(event, state)

  defp type(event, state), do: {:noreply, write(state, Keymap.to_bytes(event, state.input))}

  # Anything sent to the program brings the view back to the live screen.
  defp write(state, nil), do: state
  defp write(%{active: nil} = state, _bytes), do: state

  defp write(state, bytes) do
    if state.scroll > 0 or state.view_moved, do: on_screen(state, &Screen.scroll(&1, :bottom))
    Pty.write(state.active, bytes)
    %{state | view_moved: false}
  end

  ## The mouse, when the program doesn't want it

  defp local_mouse({:mouse, :press, 0, col, row, _mods, clicks}, state) do
    on_screen(state, &Screen.select(&1, {:start, {row, col}, clicks}))
    %{state | selecting: true}
  end

  defp local_mouse({:mouse, :motion, 0, col, row, _mods, _}, %{selecting: true} = state) do
    on_screen(state, &Screen.select(&1, {:extend, {row, col}}))
    state
  end

  defp local_mouse({:mouse, :release, 0, _col, _row, _mods, _}, %{selecting: true} = state) do
    case {on_screen(state, &Screen.select(&1, :finish)), state.config.copy_on_select} do
      {text, copy} when is_binary(text) and text != "" and copy != false ->
        send_port(state, Protocol.clipboard(:primary, text))
        if copy == :clipboard, do: send_port(state, Protocol.clipboard(:clipboard, text))

      _ ->
        :ok
    end

    %{state | selecting: false}
  end

  defp local_mouse({:mouse, :press, 1, _col, _row, _mods, _}, state) do
    send_port(state, Protocol.paste_primary())
    state
  end

  # On the alternate screen there's no scrollback: the wheel sends arrow
  # keys instead, so less, man and git log scroll (xterm's alternateScroll).
  defp local_mouse({:mouse, :wheel, dir, _col, _row, _mods, _}, %{alt_screen: true} = state) do
    key = if dir == 0, do: Keymap.key(:up), else: Keymap.key(:down)
    bytes = Keymap.to_bytes({:key, key, 0}, state.input)
    write(state, :binary.copy(bytes, state.config.wheel_lines))
  end

  defp local_mouse({:mouse, :wheel, dir, _col, _row, _mods, _}, state) do
    lines = if dir == 0, do: state.config.wheel_lines, else: -state.config.wheel_lines
    on_screen(state, &Screen.scroll(&1, {:lines, lines}))
    %{state | view_moved: true}
  end

  defp local_mouse(_event, state), do: state

  ## Search mode

  defp search_key({:key, key, mods}, state) do
    cond do
      key == Keymap.key(:escape) ->
        on_screen(state, &Screen.end_search/1)
        update_status(%{state | search: nil})

      key == Keymap.key(:enter) ->
        search_for(state, state.search.query, if(Keymap.shift?(mods), do: :newer, else: :older))

      key == Keymap.key(:backspace) ->
        query = state.search.query |> String.graphemes() |> Enum.drop(-1) |> Enum.join()
        search_for(state, query, :start)

      true ->
        state
    end
  end

  defp search_for(state, query, direction) do
    found = on_screen(state, &Screen.search(&1, query, direction)) == :found

    update_status(%{
      state
      | search: %{query: query, found: found or query == ""},
        view_moved: true
    })
  end

  defp on_screen(%{active: nil}, _fun), do: nil
  defp on_screen(state, fun), do: catch_exit(fn -> fun.(state.active) end)

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

  defp run(action, state)
       when action in [:scroll_page_up, :scroll_page_down, :scroll_top, :scroll_bottom] do
    how =
      %{
        scroll_page_up: :page_up,
        scroll_page_down: :page_down,
        scroll_top: :top,
        scroll_bottom: :bottom
      }[action]

    on_screen(state, &Screen.scroll(&1, how))
    %{state | view_moved: true}
  end

  defp run(:search, %{search: nil} = state),
    do: update_status(%{state | search: %{query: "", found: true}})

  defp run(:search, state), do: state

  defp run(:copy, state) do
    case on_screen(state, &Screen.selection_text/1) do
      text when is_binary(text) and text != "" ->
        send_port(state, Protocol.clipboard(:clipboard, text))

      _ ->
        :ok
    end

    state
  end

  # Open the config file in the app the desktop uses for it, creating it
  # from the example first. The renderer opens it (SDL_OpenURL): it runs in
  # the user's session, with the right display.
  defp run(:open_config, state) do
    path = Config.path()

    unless File.exists?(path) do
      File.mkdir_p!(Path.dirname(path))
      File.cp!(Path.join(:code.priv_dir(:guiltty), "config.example.exs"), path)
    end

    send_port(state, Protocol.open_url("file://" <> path))
    state
  end

  defp run(:zoom_in, state), do: zoom(state, state.zoom + 1)
  defp run(:zoom_out, state), do: zoom(state, state.zoom - 1)
  defp run(:zoom_reset, state), do: zoom(state, 0)

  defp run(_unknown, state), do: state

  defp switch(state, to) do
    Tabs.switch(to)
    state
  end

  # Zoom changes the font size, and so the cell size and the grid: the
  # renderer works out the new grid and sends a resize.
  defp zoom(state, steps) do
    state = %{state | zoom: steps}
    size = font(state).size
    state = %{state | zoom: size - state.config.font.size}
    send_port(state, Protocol.font(font(state)))
    state
  end

  defp font(state) do
    %{
      state.config.font
      | size: (state.config.font.size + state.zoom) |> max(@min_font) |> min(@max_font)
    }
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
    if state.search, do: on_screen(state, &Screen.end_search/1)

    %{
      state
      | active: id,
        screen_ref: nil,
        pending: false,
        title: nil,
        search: nil,
        selecting: false
    }
    |> view(id)
    |> update_status()
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
        # The program's cursor shape if it set one, otherwise the user's.
        default = {state.config.cursor.style, state.config.cursor.blink}
        send_port(state, Protocol.rows(%{update | cursor_style: update.cursor_style || default}))

        if update.title != state.title,
          do: send_port(state, Protocol.title(window_title(update.title)))

        %{
          state
          | awaiting_frame: true,
            pending: false,
            input: update.input,
            title: update.title,
            alt_screen: update.alt_screen,
            scroll: update.scroll,
            scrollback: update.scrollback
        }
        |> update_status()

      _gone ->
        state
    end
  end

  ## The status line, at the right of the tab bar

  defp update_status(state) do
    status = status_text(state)
    if status != state.status, do: send_port(state, Protocol.status(status))
    %{state | status: status}
  end

  defp status_text(%{search: %{query: query, found: found}}),
    do: "find: #{query}" <> if(found, do: "", else: "  (not found)")

  defp status_text(%{scroll: scroll, scrollback: total}) when scroll > 0,
    do: "scrollback #{scroll}/#{total}"

  defp status_text(_state), do: ""

  defp window_title(""), do: "guiltty"
  defp window_title(title), do: title

  ## Config

  defp apply_config(state, config) do
    if config.theme != state.config.theme do
      send_port(state, Protocol.theme(config.theme))
      # The renderer resolved every cell with the old theme: send them all again.
      if state.active, do: catch_exit(fn -> Screen.subscribe(state.active, self()) end)
    end

    old_font = font(state)
    old = state.config
    state = %{state | config: config, bindings: parse_bindings(config.keys)}
    if font(state) != old_font, do: send_port(state, Protocol.font(font(state)))
    if options(config) != options(old), do: send_port(state, Protocol.options(options(config)))

    # A new default cursor shows with the next update, and bold-is-bright
    # changes the colors of rows the renderer already has: ask for every
    # row again.
    if (config.cursor != old.cursor or config.bold_is_bright != old.bold_is_bright) and
         state.active,
       do: catch_exit(fn -> Screen.subscribe(state.active, self()) end)

    state
  end

  defp options(config) do
    %{
      padding: config.window.padding,
      opacity: config.window.opacity,
      bold_is_bright: config.bold_is_bright
    }
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

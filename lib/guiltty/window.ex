defmodule Guiltty.Window do
  @moduledoc """
  Owns the renderer port: shows the active tab, turns the renderer's events
  into bytes for that tab's shell, and handles guiltty's own keys.

  The renderer is a separate OS process, so if it crashes only this process
  notices; the supervisor starts a new Window, which starts a new renderer
  and redraws from the Screen. When the user closes the window the renderer
  exits with status 0 and this process stops normally, closing every tab
  of its desk that isn't locked (Ctrl+Shift+L). With none locked, the desk
  ends (and guiltty, if it was the last); locked tabs keep running.

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

  ## Renaming a tab

  The rename key (Ctrl+Shift+R) works the same way: typing goes to the
  tab's new name, shown in the status, Enter sets it (empty gives the
  program's title back) and Escape leaves it as it was.

  ## Closing a busy tab

  Closing a tab whose shell is running a program (`vim`, `ssh`, a build)
  asks first: the status says what's running, and only a second press
  within a few seconds closes it.
  """

  use GenServer, restart: :transient

  require Logger

  alias Guiltty.{Cheatsheet, Config, Keymap, Lifeline, Session, Tabs}
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
  Options: `:tabs` (its desk's `Guiltty.Tabs`, required), `:renderer` (a
  binary in priv/) and `:env` (extra environment for the renderer, as
  `[{charlist, charlist}]`). Windows have no global name: there can be
  many, one per desk.
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    config = Config.get()
    renderer = Keyword.get(opts, :renderer) || renderer_for(config.renderer)
    env = Keyword.get(opts, :env, [])
    port = open_renderer(renderer, env)

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
      # this window's tabs (Guiltty.Tabs): every window has its own
      desk_tabs: Keyword.fetch!(opts, :tabs),
      port: port,
      # the renderer binary, and its environment (for a fallback)
      renderer: renderer,
      env: env,
      # a warning to show once the renderer says hello, and whether this
      # renderer has drawn a frame yet
      notice: nil,
      drawn: false,
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
      status: {:normal, ""},
      # the config file's error, one line, until it loads again
      config_error: nil,
      # tabs that stay when the window closes, the broadcast group
      # (id => host) and its lost tabs; Tabs owns all three
      locked: MapSet.new(),
      group: %{},
      lost: [],
      # a short-lived warning in the status
      flash: nil,
      # the tab waiting for a second Ctrl+Shift+B to join as a local tab
      confirm_local: nil,
      # the busy tab waiting for a second close key
      confirm_close: nil,
      # rename mode: %{text: binary}
      rename: nil,
      # GUILTTY_RECORD's file, or nil
      recording: open_recording(),
      # the cheatsheet, while it's open: %{lines: [row], top: first row shown}
      cheatsheet: nil
    }

    {:ok, state, @hello_timeout}
  end

  # The binary for the `renderer` setting, or for GUILTTY_RENDERER, which
  # wins over it (to try the other one without editing the config). An
  # explicit `config :guiltty, renderer: "..."` (the tests' sanitizer
  # builds) wins over both. Once Vulkan has failed to start, later windows
  # go straight to OpenGL.
  defp renderer_for(setting) do
    setting = renderer_setting(System.get_env("GUILTTY_RENDERER"), setting)

    cond do
      binary = Application.get_env(:guiltty, :renderer) -> to_string(binary)
      setting == :gl or Application.get_env(:guiltty, :vulkan_failed, false) -> "guiltty_gl"
      true -> "guiltty_vk"
    end
  end

  @doc false
  # GUILTTY_RENDERER's value over the config's setting.
  def renderer_setting(value, _setting) when value in ["gl", "opengl"], do: :gl
  def renderer_setting("vulkan", _setting), do: :vulkan
  def renderer_setting(value, setting) when value in [nil, ""], do: setting

  def renderer_setting(value, setting) do
    Logger.warning("window: GUILTTY_RENDERER=#{value} isn't gl or vulkan; using #{setting}")
    setting
  end

  defp open_renderer(renderer, env) do
    Port.open({:spawn_executable, Path.join(:code.priv_dir(:guiltty), renderer)}, [
      :binary,
      :exit_status,
      :use_stdio,
      packet: 4,
      env: env
    ])
  end

  # Vulkan died before drawing anything: no driver, or no GPU that can
  # show this window. (Its hello comes before it even makes a window, so
  # "before the first frame" is the sign, not "before the hello".) Draw
  # with OpenGL instead, in this same Window: forget the handshake and the
  # tab being shown, so the new renderer's hello does both again. Later
  # windows go straight to OpenGL, until guiltty restarts.
  defp fall_back(%{renderer: "guiltty_vk" <> build, drawn: false} = state, why) do
    Logger.warning("window: the Vulkan renderer #{why}; drawing with OpenGL")
    Application.put_env(:guiltty, :vulkan_failed, true)
    if why == "didn't say hello", do: Port.close(state.port)
    if state.active, do: catch_exit(fn -> Screen.unsubscribe(state.active, self()) end)
    if state.screen_ref, do: Process.demonitor(state.screen_ref, [:flush])
    renderer = "guiltty_gl" <> build

    {:noreply,
     %{
       state
       | port: open_renderer(renderer, state.env),
         renderer: renderer,
         notice: "Vulkan couldn't start: drawing with OpenGL (see the log)",
         ready: false,
         active: nil,
         screen_ref: nil,
         tabs: [],
         awaiting_frame: false,
         pending: false,
         status: {:normal, ""}
     }, @hello_timeout}
  end

  defp fall_back(_state, _why), do: :no_fallback

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
  #
  # Then the tabs end too, all but the locked ones. With none locked, the
  # last one ending stops guiltty; locked tabs keep running, and
  # the next window shows them again.
  def handle_info({port, {:exit_status, 0}}, %{port: port} = state) do
    catch_exit(fn -> Tabs.close_unlocked(state.desk_tabs) end)
    {:stop, {:shutdown, :window_closed}, %{state | port: nil}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    case fall_back(state, "exited with status #{status}") do
      :no_fallback -> {:stop, {:renderer_exited, status}, %{state | port: nil}}
      fallen_back -> fallen_back
    end
  end

  def handle_info(:timeout, state) do
    case fall_back(state, "didn't say hello") do
      :no_fallback -> {:stop, :no_hello_from_renderer, state}
      fallen_back -> fallen_back
    end
  end

  ## Screen and tabs

  def handle_info({:screen_dirty, id}, %{active: id} = state), do: {:noreply, pull(state)}
  def handle_info({:screen_dirty, _other}, state), do: {:noreply, state}

  def handle_info({:tabs, info}, state), do: {:noreply, show_tabs(state, info)}

  def handle_info(:flash_over, state),
    do: {:noreply, update_status(%{state | flash: nil, confirm_local: nil, confirm_close: nil})}

  # The active Screen restarted (it crashed, or its session did). The new
  # one doesn't know about us, so view it again.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{screen_ref: ref} = state) do
    {:noreply, view(%{state | screen_ref: nil, awaiting_frame: false}, state.active)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}
  def handle_info({:view, id}, %{active: id} = state), do: {:noreply, view(state, id)}
  def handle_info({:view, _old}, state), do: {:noreply, state}

  def handle_info({:parser_restarted, _id}, state) do
    if state.ready, do: send_port(state, Protocol.halo(@halo_color, @halo_ms))
    {:noreply, state}
  end

  def handle_info({:config, config}, state),
    do: {:noreply, %{apply_config(state, config) | config_error: nil} |> update_status()}

  def handle_info({:config_error, message}, state),
    do: {:noreply, update_status(%{state | config_error: message})}

  def handle_info(:raise, state) do
    if state.ready, do: send_port(state, Protocol.raise_window())
    {:noreply, state}
  end

  ## Renderer events

  defp handle_event({:hello, version, backend}, state) do
    if version == Protocol.version() do
      Logger.debug("window: renderer #{backend} speaks protocol #{version}")
      info = Tabs.attach_window(state.desk_tabs, self())
      {cols, rows} = Session.size(info.active)
      setup = Protocol.setup(cols, rows, state.config.theme, font(state), options(state.config))
      send_port(state, setup)
      state = show_tabs(%{state | ready: true, size: {cols, rows}}, info)
      # Anything that waited for the handshake (a config error, a fallback
      # notice) goes now.
      state =
        if state.notice, do: flash(%{state | notice: nil}, state.notice, 10_000), else: state

      {:noreply, update_status(state)}
    else
      {:stop, {:protocol_mismatch, renderer: version, window: Protocol.version()}, state}
    end
  end

  defp handle_event({:frame, us}, state) do
    :telemetry.execute([:guiltty, :renderer, :frame], %{duration: us}, %{})
    # The end of a window's startup, for measuring it (book chapter 22).
    unless state.drawn, do: Logger.debug("window: first frame drawn")
    state = %{state | awaiting_frame: false, drawn: true}
    {:noreply, if(state.pending, do: pull(state), else: state)}
  end

  # The user resized the window and the renderer worked out the new grid.
  defp handle_event({:resize, cols, rows}, state) do
    Tabs.resize(state.desk_tabs, cols, rows)
    state = %{state | size: {cols, rows}}

    {:noreply,
     if(state.cheatsheet, do: open_cheatsheet(state, state.cheatsheet.top), else: state)}
  end

  # While the cheatsheet is open, keys, text and the mouse are its own: the
  # shell gets nothing.
  defp handle_event({:key, _, _} = event, %{cheatsheet: %{}} = state),
    do: {:noreply, cheatsheet_key(event, state)}

  defp handle_event({:text, text}, %{cheatsheet: %{}} = state) do
    case text do
      "q" -> {:noreply, close_cheatsheet(state)}
      "j" -> {:noreply, scroll_cheatsheet(state, 1)}
      "k" -> {:noreply, scroll_cheatsheet(state, -1)}
      _ -> {:noreply, state}
    end
  end

  defp handle_event(
         {:mouse, :wheel, dir, _col, _row, _mods, _clicks},
         %{cheatsheet: %{}} = state
       ),
       do: {:noreply, scroll_cheatsheet(state, if(dir == 0, do: -3, else: 3))}

  defp handle_event({:paste, _text}, %{cheatsheet: %{}} = state), do: {:noreply, state}

  defp handle_event({:mouse, _, _, _, _, _, _}, %{cheatsheet: %{}} = state),
    do: {:noreply, state}

  defp handle_event({:tab_click, index}, state) do
    Tabs.switch(state.desk_tabs, index)
    {:noreply, state}
  end

  defp handle_event({:paste, text}, %{rename: %{}} = state),
    do: {:noreply, rename_to(state, state.rename.text <> String.replace(text, ~r/\s+/, " "))}

  defp handle_event({:paste, text}, state) do
    {:noreply, input(state, Keymap.paste(text, state.input))}
  end

  defp handle_event({:mouse, _kind, _button, _col, _row, mods, _clicks} = event, state) do
    if state.input.mouse != nil and not Keymap.shift?(mods),
      do: {:noreply, write(state, Keymap.mouse(event, state.input))},
      else: {:noreply, local_mouse(event, state)}
  end

  defp handle_event({:key, _, _} = event, state) do
    case Enum.find(state.bindings, fn {_action, binding} -> Keymap.matches?(event, binding) end) do
      {action, _binding} -> {:noreply, run(action, state)}
      nil when state.rename != nil -> {:noreply, rename_key(event, state)}
      nil when state.search != nil -> {:noreply, search_key(event, state)}
      nil -> type(event, state)
    end
  end

  defp handle_event({:text, text}, %{rename: %{}} = state),
    do: {:noreply, rename_to(state, state.rename.text <> text)}

  defp handle_event({:text, text}, %{search: %{}} = state),
    do: {:noreply, search_for(state, state.search.query <> text, :start)}

  defp handle_event({:text, _} = event, state), do: type(event, state)

  defp type(event, state), do: {:noreply, input(state, Keymap.to_bytes(event, state.input))}

  # What you type or paste: in a broadcast group it goes to every tab in
  # the group, through Tabs, which checks first that none lost its
  # connection (see Guiltty.Tabs, "Broadcast"). Mouse reports and the like
  # use write/2: they only make sense for the tab you're looking at.
  defp input(state, nil), do: state
  defp input(%{active: nil} = state, _bytes), do: state

  defp input(state, bytes) do
    if Map.has_key?(state.group, state.active) do
      if state.scroll > 0 or state.view_moved, do: on_screen(state, &Screen.scroll(&1, :bottom))
      catch_exit(fn -> Tabs.send_input(state.desk_tabs, state.active, bytes) end)
      %{state | view_moved: false}
    else
      write(state, bytes)
    end
  end

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

  ## Rename mode

  @max_name 40

  defp rename_key({:key, key, _mods}, state) do
    cond do
      key == Keymap.key(:escape) ->
        update_status(%{state | rename: nil})

      key == Keymap.key(:enter) ->
        name = String.trim(state.rename.text)
        catch_exit(fn -> Tabs.rename(state.desk_tabs, state.active, name) end)
        update_status(%{state | rename: nil})

      key == Keymap.key(:backspace) ->
        text = state.rename.text |> String.graphemes() |> Enum.drop(-1) |> Enum.join()
        rename_to(state, text)

      true ->
        state
    end
  end

  defp rename_to(state, text),
    do: update_status(%{state | rename: %{text: String.slice(text, 0, @max_name)}})

  defp on_screen(%{active: nil}, _fun), do: nil
  defp on_screen(state, fun), do: catch_exit(fn -> fun.(state.active) end)

  ## guiltty's own keys

  # A new window, fresh, on the same display as this one: the renderer
  # gets this window's environment (DISPLAY and the rest).
  defp run(:new_window, state) do
    case Lifeline.open(window: [env: state.env], fresh: true) do
      {:ok, _desk} -> state
      {:error, reason} -> flash(state, "couldn't open a window: #{inspect(reason)}")
    end
  end

  defp run(:new_tab, state) do
    Tabs.new_tab(state.desk_tabs)
    state
  end

  defp run(:close_tab, %{active: nil} = state), do: state

  # A tab running a program asks first; a second press closes it.
  defp run(:close_tab, state) do
    busy =
      if state.confirm_close != state.active,
        do: catch_exit(fn -> Pty.busy(state.active) end)

    if is_binary(busy) do
      flash(%{state | confirm_close: state.active}, "#{busy} is running: press again to close")
    else
      Tabs.close(state.desk_tabs, state.active)
      update_status(%{state | confirm_close: nil, flash: nil})
    end
  end

  defp run(:move_tab_left, state), do: move(state, :left)
  defp run(:move_tab_right, state), do: move(state, :right)

  defp run(:rename_tab, %{active: nil} = state), do: state

  # Starts from the name it shows now, to edit it.
  defp run(:rename_tab, state) do
    {_id, title} = Enum.find(state.tabs, {nil, ""}, fn {id, _} -> id == state.active end)
    rename_to(%{state | search: nil}, title)
  end

  defp run(:clear_scrollback, state) do
    if state.search, do: on_screen(state, &Screen.end_search/1)
    on_screen(state, &Screen.clear_scrollback/1)
    update_status(%{state | search: nil, view_moved: false})
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
    do: update_status(%{state | search: %{query: "", found: true}, rename: nil})

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

  defp run(:cheatsheet, state), do: open_cheatsheet(state, 0)

  defp run(:broadcast, %{active: nil} = state), do: state

  # A tab running ssh joins at once. A local one only on a second press:
  # joining a local tab must be on purpose, so a tab whose ssh just died
  # can't slip in by accident.
  defp run(:broadcast, state) do
    programs = state.config.broadcast_programs
    local? = state.confirm_local == state.active

    case catch_exit(fn ->
           Tabs.toggle_broadcast(state.desk_tabs, state.active, programs, local: local?)
         end) do
      {:error, {:not_allowed, program}} ->
        state = %{state | confirm_local: state.active}
        flash(state, "this tab is local (#{program}): Ctrl+Shift+B again adds it as a local tab")

      _ ->
        update_status(%{state | confirm_local: nil, flash: nil})
    end
  end

  defp run(:lock_tab, state) do
    if state.active, do: catch_exit(fn -> Tabs.toggle_lock(state.desk_tabs, state.active) end)
    state
  end

  defp run(:zoom_in, state), do: zoom(state, state.zoom + 1)
  defp run(:zoom_out, state), do: zoom(state, state.zoom - 1)
  defp run(:zoom_reset, state), do: zoom(state, 0)

  defp run(_unknown, state), do: state

  ## The cheatsheet
  #
  # Guiltty.Cheatsheet draws every key into rows, from the config. Instead
  # of the tab's screen, the Window sends a screenful of those rows; on
  # closing, the Screen sends all of its rows again.

  defp open_cheatsheet(state, top) do
    {cols, _rows} = state.size
    state = %{state | cheatsheet: %{lines: Cheatsheet.render(state.config, cols), top: 0}}
    scroll_cheatsheet(state, top)
  end

  defp scroll_cheatsheet(state, by) do
    {cols, rows} = state.size
    %{lines: lines, top: top} = state.cheatsheet
    top = (top + by) |> min(length(lines) - rows) |> max(0)
    blank = :binary.copy(<<?\s::32, 0::16, 0::32, 0::32>>, cols)
    shown = lines |> Enum.drop(top) |> Enum.take(rows)
    shown = shown ++ List.duplicate(blank, rows - length(shown))

    send_port(
      state,
      Protocol.rows(%{
        size: {cols, rows},
        rows: Enum.with_index(shown, fn line, i -> {i, line} end),
        cursor: {0, 0},
        cursor_visible: false
      })
    )

    put_in(state.cheatsheet.top, top)
  end

  defp close_cheatsheet(state) do
    state = %{state | cheatsheet: nil, pending: false}
    if state.active, do: catch_exit(fn -> Screen.subscribe(state.active, self()) end)
    state
  end

  defp cheatsheet_key({:key, key, _mods} = event, state) do
    closes =
      key == Keymap.key(:escape) or
        Enum.any?(state.bindings, fn {action, b} ->
          action == :cheatsheet and Keymap.matches?(event, b)
        end)

    {_cols, rows} = state.size

    cond do
      closes -> close_cheatsheet(state)
      key == Keymap.key(:down) -> scroll_cheatsheet(state, 1)
      key == Keymap.key(:up) -> scroll_cheatsheet(state, -1)
      key == Keymap.key(:page_down) -> scroll_cheatsheet(state, rows - 1)
      key == Keymap.key(:page_up) -> scroll_cheatsheet(state, -(rows - 1))
      key == Keymap.key(:home) -> scroll_cheatsheet(state, -length(state.cheatsheet.lines))
      key == Keymap.key(:end) -> scroll_cheatsheet(state, length(state.cheatsheet.lines))
      true -> state
    end
  end

  defp switch(state, to) do
    Tabs.switch(state.desk_tabs, to)
    state
  end

  defp move(state, direction) do
    catch_exit(fn -> Tabs.move(state.desk_tabs, direction) end)
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

  # A locked tab shows a lock before its title; a tab with something new
  # since you looked shows a dot (output) or a bell, before that.
  defp show_tabs(state, %{list: tabs, active: active} = info) do
    state = %{state | locked: info.locked, group: info.group, lost: MapSet.to_list(info.lost)}
    marks = Map.get(info, :marks, %{})

    titles =
      Enum.map(tabs, fn {id, title} ->
        title = if title == "", do: "shell", else: title
        title = if MapSet.member?(state.locked, id), do: "🔒 " <> title, else: title

        title =
          cond do
            id in state.lost -> "⚠ " <> title
            state.group[id] == :local -> "🏠 " <> title
            Map.has_key?(state.group, id) -> "📡 " <> title
            true -> title
          end

        case marks[id] do
          :bell -> "🔔 " <> title
          :activity -> "● " <> title
          nil -> title
        end
      end)

    index = Enum.find_index(tabs, fn {id, _} -> id == active end) || 0
    send_port(state, Protocol.tabs(titles, index))
    state = %{state | tabs: tabs}
    state = if active != state.active, do: switch_view(state, active), else: state
    update_status(state)
  end

  defp switch_view(state, id) do
    state = %{state | cheatsheet: nil}
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
        rename: nil,
        confirm_close: nil,
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
  # The cheatsheet covers the screen; closing it brings every row back.
  defp pull(%{cheatsheet: %{}} = state), do: state
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

  # A warning that goes away by itself after a few seconds.
  defp flash(state, text, ms \\ 3_000) do
    Process.send_after(self(), :flash_over, ms)
    update_status(%{state | flash: text})
  end

  # Shown, most important first: the search you're typing, a broken config
  # (in red, until the file loads again), where you are in the scrollback.
  # Before the handshake the renderer accepts nothing but the setup; the
  # status waits, and goes out right after it.
  defp update_status(%{ready: false} = state), do: state

  defp update_status(state) do
    {style, text} = status = status_text(state)
    if status != state.status, do: send_port(state, Protocol.status(style, text))
    %{state | status: status}
  end

  defp status_text(%{rename: %{text: text}}), do: {:normal, "rename tab: #{text}"}

  defp status_text(%{search: %{query: query, found: found}}),
    do: {:normal, "find: #{query}" <> if(found, do: "", else: "  (not found)")}

  defp status_text(%{flash: flash}) when is_binary(flash), do: {:warning, flash}

  defp status_text(%{config_error: error}) when is_binary(error),
    do: {:warning, "⚠ " <> error}

  # A lost connection in the broadcast group: say which. Typing goes
  # nowhere until that tab leaves the group (Ctrl+Shift+B on it) or closes.
  defp status_text(%{lost: [_ | _] = lost} = state) do
    names =
      Enum.map_join(lost, ", ", fn id ->
        index = Enum.find_index(state.tabs, fn {tab, _} -> tab == id end)
        host = state.group[id]
        "tab #{(index || 0) + 1}" <> if(host, do: " (#{host})", else: "")
      end)

    # Short, so the tabs stay visible; how to go on is on the cheatsheet.
    {:warning, "⚠ broadcast paused: #{names} disconnected"}
  end

  defp status_text(%{group: group, active: active}) when is_map_key(group, active) do
    count = map_size(group)
    local = Enum.count(group, fn {_id, host} -> host == :local end)
    tabs = "#{count} tab#{if count == 1, do: "", else: "s"}"
    {:normal, "📡 broadcast: #{tabs}" <> if(local > 0, do: " (#{local} local)", else: "")}
  end

  defp status_text(%{scroll: scroll, scrollback: total}) when scroll > 0,
    do: {:normal, "scrollback #{scroll}/#{total}"}

  defp status_text(_state), do: {:normal, ""}

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

    # The keys on the cheatsheet may have changed.
    if state.cheatsheet, do: open_cheatsheet(state, state.cheatsheet.top), else: state
  end

  defp options(config) do
    %{
      padding: config.window.padding,
      opacity: config.window.opacity,
      bold_is_bright: config.bold_is_bright,
      tab_bar: config.tab_bar,
      ligatures: config.ligatures
    }
  end

  defp send_port(%{port: port} = state, message) when is_port(port) do
    record(state, message)
    Port.command(port, message)
  end

  defp send_port(_state, _message), do: :ok

  # With GUILTTY_RECORD=path, every message to the renderer is also written
  # there, framed as on the port (a 4-byte length, then the message), for
  # `guiltty_gl --replay path`: the renderer tested with no Elixir at all.
  defp open_recording do
    case System.get_env("GUILTTY_RECORD") do
      nil -> nil
      "" -> nil
      path -> File.open!(path, [:write, :binary])
    end
  end

  defp record(%{recording: nil}, _message), do: :ok

  defp record(%{recording: file}, message),
    do: IO.binwrite(file, [<<IO.iodata_length(message)::32>>, message])

  defp catch_exit(fun) do
    fun.()
  catch
    :exit, _ -> :exit
  end

  @impl true
  def terminate(_reason, state) do
    :telemetry.detach(state.handler)
    if state.recording, do: File.close(state.recording)
    # Closing stdin tells the renderer to quit.
    if is_port(state.port) and Port.info(state.port), do: Port.close(state.port)
    :ok
  end
end

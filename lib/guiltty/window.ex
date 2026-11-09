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

  The Window doesn't forward every screen change. It views the Screen of
  every pane of the active tab; each says `{:screen_dirty, id}` when
  something changed. The Window takes the update of every pane that said
  so (`Screen.take_update/1`), stitches them into one, sends it, and takes
  the next only after the renderer reports it drew a frame. So the
  renderer gets at most one update per frame, however fast a program
  prints. Frame times are emitted as `[:guiltty, :renderer, :frame]`
  (`%{duration: microseconds}`).

  ## The mouse

  Mouse events go to the program when it asked for them (mouse reporting
  modes), unless Shift is held. Otherwise guiltty uses them: the left
  button selects (double click: words, triple: lines) and copies the
  selection to the primary selection, the middle button pastes it, the right
  button copies what's selected to the clipboard and pastes it at the prompt
  under the pointer, and the wheel scrolls back (or, on the alternate screen, sends arrow keys, so
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

  ## Split panes

  A tab can be split into panes (`Guiltty.Tabs`, `Guiltty.Layout`). The
  renderer still draws one grid: the Window views every pane's Screen and
  stitches their rows together around one-cell separators
  (`Guiltty.Window.Compose`). The focused pane gets what you type, and its
  cursor is the one drawn. A click focuses the pane under it; a drag stays
  in the pane it started in; the wheel scrolls the pane under the pointer.

  ## The AI key

  Opens the command in the `ai` setting, in a pane beside you or a tab of its
  own, and goes back and forth between it and where you were. It's a program in a
  pane, nothing more: guiltty talks to no AI itself. What's selected goes to its
  prompt, and nothing else on your screen ever does: terminals show passwords
  and tokens, and sending them somewhere must be something you chose. It's a paste
  with no Enter, so nothing is sent until you say so.

  ## What programs can ask of the window

  A program can set a pane's colors, and the clipboard (OSC 52, unless
  `clipboard_write` is off): only the focused pane's request counts, so a
  background job can't replace what you copied. It can ask to hear about
  focus (mode 1004): `CSI I` when its pane gets the keyboard, `CSI O` when it
  leaves. And text can be a link (OSC 8): Ctrl+click opens it, for http,
  https, mailto and file URIs.

  ## Closing a busy tab

  Closing a tab whose shell is running a program (`vim`, `ssh`, a build)
  asks first: the status says what's running, and only a second press
  within a few seconds closes it.
  """

  use GenServer, restart: :transient

  import Bitwise

  require Logger

  alias Guiltty.{Cheatsheet, Config, Keymap, Lifeline, Session, Tabs}
  alias Guiltty.Session.{Pty, Screen}
  alias Guiltty.Window.{Compose, Protocol}

  @hello_timeout 5_000
  @resubscribe_ms 50
  @halo_color {0x81, 0xA2, 0xBE}
  @halo_ms 400
  @min_font 6
  @max_font 96
  @default_input Guiltty.Grid.default_input()
  # SDL_KMOD_CTRL
  @kmod_ctrl 0x00C0
  @link_schemes ~w(http https mailto file)
  # How long a new AI tool has to ask for bracketed paste, before what's selected
  # goes to it anyway, on one line.
  @ai_paste_ms 5_000

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
      # the focused pane's session (what you type into), the tab it's in,
      # and how that tab's panes are stitched into one grid
      active: nil,
      active_tab: nil,
      compose: nil,
      # the active tab's panes as Tabs said (its info's :panes), and the
      # layout the compose was made for
      panes: nil,
      layout_key: nil,
      # each tab's panes
      members: %{},
      # monitor ref => pane, one per pane's Screen being viewed
      screen_refs: %{},
      # pane => what its last update said: input modes, title, cursor...
      pane_state: %{},
      # panes with something new to take, and whether the next update
      # sends every row (a new layout or focus)
      dirty: MapSet.new(),
      full: false,
      # the pane the mouse button went down in: a drag stays in it
      mouse_pane: nil,
      cell_pixels: nil,
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
      cheatsheet: nil,
      # the images the renderer has, by uid (see show_graphics/2)
      sent_images: MapSet.new(),
      # the AI tool's session, per tab (or :tab when it has a tab of its own)
      ai_panes: %{},
      # where the AI key came from, to go back
      ai_return: nil,
      # what's selected, waiting for a new AI tool to be ready: %{pane:, text:}
      ai_paste: nil,
      # the window has the keyboard (for focus events)
      focused: true,
      # what the last key event said beyond the key (see Guiltty.Keymap)
      key_extra: nil,
      # keys guiltty kept for itself: a program shouldn't see them released
      bound_keys: MapSet.new(),
      # a key already sent as an escape code also arrives as this text
      swallow_text: nil,
      # the cursor color a program set, and the one the renderer has
      sent_cursor_color: nil,
      # a tab was switched to: its pane hears about focus once its first
      # update says whether it asked to
      focus_pending: false
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
    state = unview_all(state)
    renderer = "guiltty_gl" <> build

    {:noreply,
     %{
       state
       | port: open_renderer(renderer, state.env),
         renderer: renderer,
         notice: "Vulkan couldn't start: drawing with OpenGL (see the log)",
         ready: false,
         active: nil,
         active_tab: nil,
         compose: nil,
         panes: nil,
         layout_key: nil,
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

  def handle_info({:screen_dirty, id}, state) do
    if shown?(state, id),
      do: {:noreply, pull(%{state | dirty: MapSet.put(state.dirty, id)})},
      else: {:noreply, state}
  end

  def handle_info({:tabs, info}, state), do: {:noreply, show_tabs(state, info)}

  def handle_info(:flash_over, state),
    do: {:noreply, update_status(%{state | flash: nil, confirm_local: nil, confirm_close: nil})}

  # A shown pane's Screen restarted (it crashed, or its session did). The
  # new one doesn't know about us, so view it again.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{screen_refs: refs} = state)
      when is_map_key(refs, ref) do
    {id, refs} = Map.pop(refs, ref)
    {:noreply, view(%{state | screen_refs: refs, awaiting_frame: false}, id)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:view, id}, state) do
    if shown?(state, id), do: {:noreply, view(state, id)}, else: {:noreply, state}
  end

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

  # OSC 52 from a pane's program. Only the pane with the keyboard, so nothing
  # running in the background can replace what you copied.
  def handle_info({:clipboard, id, {target, text}}, %{active: id} = state) do
    if state.config.clipboard_write, do: send_port(state, Protocol.clipboard(target, text))
    {:noreply, state}
  end

  def handle_info({:clipboard, _id, _request}, state), do: {:noreply, state}

  def handle_info({:ai_paste_late, pane}, %{ai_paste: %{pane: pane}} = state),
    do: {:noreply, deliver_ai_paste(state)}

  def handle_info({:ai_paste_late, _pane}, state), do: {:noreply, state}

  ## Renderer events

  defp handle_event({:hello, version, backend}, state) do
    if version == Protocol.version() do
      Logger.debug("window: renderer #{backend} speaks protocol #{version}")
      info = Tabs.attach_window(state.desk_tabs, self())
      {cols, rows} = info.size
      setup = Protocol.setup(cols, rows, state.config.theme, font(state), options(state.config))
      send_port(state, setup)
      send_port(state, tab_style(state.config))
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
  defp handle_event({:resize, cols, rows, cell_pixels}, state) do
    Tabs.resize(state.desk_tabs, cols, rows, cell_pixels)
    state = %{state | size: {cols, rows}, cell_pixels: cell_pixels}

    {:noreply,
     if(state.cheatsheet, do: open_cheatsheet(state, state.cheatsheet.top), else: state)}
  end

  # While the cheatsheet is open, keys, text and the mouse are its own: the
  # shell gets nothing.
  defp handle_event({:focus, focused}, state) do
    report_focus(state, state.active, focused)
    {:noreply, %{state | focused: focused}}
  end

  defp handle_event({:key, key, _mods, %{kind: :release}} = event, state) do
    cond do
      MapSet.member?(state.bound_keys, key) ->
        {:noreply, %{state | bound_keys: MapSet.delete(state.bound_keys, key)}}

      state.cheatsheet != nil or state.rename != nil or state.search != nil ->
        {:noreply, state}

      true ->
        {:noreply, write_key(state, event)}
    end
  end

  defp handle_event({:key, key, mods, extra}, state),
    do: handle_event({:key, key, mods}, %{state | key_extra: extra})

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

  defp handle_event({:mouse, _, _, _, _, _, _}, %{compose: nil} = state), do: {:noreply, state}

  # In the pane it's for, in that pane's own cells: to its program if it
  # asked for the mouse (and Shift isn't held), otherwise guiltty's.
  defp handle_event({:mouse, kind, button, col, row, mods, clicks}, state) do
    case mouse_target(state, kind, col, row) do
      nil ->
        {:noreply, state}

      {id, pane_col, pane_row, state} ->
        event = {:mouse, kind, button, pane_col, pane_row, mods, clicks}
        input = pane_input(state, id)

        if input.mouse != nil and not Keymap.shift?(mods),
          do: {:noreply, write_to(state, id, Keymap.mouse(event, input, state.cell_pixels))},
          else: {:noreply, local_mouse(event, id, state)}
    end
  end

  defp handle_event({:key, _, _} = event, state) do
    case Enum.find(state.bindings, fn {_action, binding} -> Keymap.matches?(event, binding) end) do
      {action, _binding} ->
        {:key, key, _mods} = event
        {:noreply, run(action, %{state | bound_keys: MapSet.put(state.bound_keys, key)})}

      nil when state.rename != nil ->
        {:noreply, rename_key(event, state)}

      nil when state.search != nil ->
        {:noreply, search_key(event, state)}

      nil ->
        type(event, state)
    end
  end

  defp handle_event({:text, text}, %{rename: %{}} = state),
    do: {:noreply, rename_to(state, state.rename.text <> text)}

  defp handle_event({:text, text}, %{search: %{}} = state),
    do: {:noreply, search_for(state, state.search.query <> text, :start)}

  # A key already sent as an escape code (Kitty's "every key" flag) also types
  # its text: that copy stays here. Composed text, like é, isn't that key.
  defp handle_event({:text, text}, %{swallow_text: text} = state),
    do: {:noreply, %{state | swallow_text: nil}}

  defp handle_event({:text, _} = event, state), do: type(event, %{state | swallow_text: nil})

  defp type({:key, key, mods}, %{key_extra: %{} = extra} = state) do
    bytes = Keymap.to_bytes({:key, key, mods, extra}, state.input)
    every_key? = (Map.get(state.input, :kitty, 0) &&& 8) != 0

    swallow =
      if every_key? and bytes != nil and extra.shifted in 0x20..0x10FFFF, do: extra.shifted

    text = if swallow, do: <<swallow::utf8>>
    {:noreply, input(%{state | swallow_text: text, key_extra: nil}, bytes)}
  end

  defp type(event, state), do: {:noreply, input(state, Keymap.to_bytes(event, state.input))}

  defp write_key(state, event) do
    case Keymap.to_bytes(event, state.input) do
      nil -> state
      bytes -> input(state, bytes)
    end
  end

  # Mode 1004: CSI I when a pane gets the keyboard, CSI O when it leaves.
  defp report_focus(_state, nil, _focused), do: :ok

  defp report_focus(state, id, focused) do
    if pane_value(state, id, :input, @default_input).focus_events,
      do: catch_exit(fn -> Pty.write(id, if(focused, do: "\e[I", else: "\e[O")) end)

    :ok
  end

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
  defp write(%{active: nil} = state, _bytes), do: state

  defp write(state, bytes) do
    if state.scroll > 0 or state.view_moved, do: on_screen(state, &Screen.scroll(&1, :bottom))
    Pty.write(state.active, bytes)
    %{state | view_moved: false}
  end

  # To one pane's program (a mouse report): its view goes back to live.
  defp write_to(state, _id, nil), do: state
  defp write_to(%{active: id} = state, id, bytes), do: write(state, bytes)

  defp write_to(state, id, bytes) do
    if pane_value(state, id, :scroll, 0) > 0, do: on_pane(id, &Screen.scroll(&1, :bottom))
    Pty.write(id, bytes)
    state
  end

  # Which pane a mouse event is for, in its own cells. A press picks the
  # pane under it, and focuses it; moving and letting go stay with that
  # pane, even past its edge, as a drag that selects does. Anything else
  # (the wheel, a move with no button down) is for the pane under the
  # pointer. On a separator: nobody's.
  defp mouse_target(%{mouse_pane: id} = state, kind, col, row)
       when kind in [:motion, :release] and id != nil do
    case Compose.rect(state.compose, id) do
      {x, y, w, h} ->
        state = if kind == :release, do: %{state | mouse_pane: nil}, else: state
        {id, (col - x) |> max(0) |> min(w - 1), (row - y) |> max(0) |> min(h - 1), state}

      nil ->
        nil
    end
  end

  defp mouse_target(state, kind, col, row) do
    case Compose.at(state.compose, col, row) do
      {:pane, id, pane_col, pane_row} ->
        state = if kind == :press, do: focus_pane(%{state | mouse_pane: id}, id), else: state
        {id, pane_col, pane_row, state}

      :separator ->
        nil
    end
  end

  defp focus_pane(%{active: id} = state, id), do: state

  defp focus_pane(state, id) do
    catch_exit(fn -> Tabs.focus(state.desk_tabs, {:pane, id}) end)
    state
  end

  ## The mouse, when the program doesn't want it

  defp local_mouse({:mouse, :press, 0, col, row, mods, clicks}, id, state) do
    link = if (mods &&& @kmod_ctrl) != 0, do: on_pane(id, &Screen.link_at(&1, {row, col}))

    if is_binary(link) do
      open_link(state, link)
    else
      on_pane(id, &Screen.select(&1, {:start, {row, col}, clicks}))
      %{state | selecting: true}
    end
  end

  defp local_mouse({:mouse, :motion, 0, col, row, _mods, _}, id, %{selecting: true} = state) do
    on_pane(id, &Screen.select(&1, {:extend, {row, col}}))
    state
  end

  defp local_mouse({:mouse, :release, 0, _col, _row, _mods, _}, id, %{selecting: true} = state) do
    case {on_pane(id, &Screen.select(&1, :finish)), state.config.copy_on_select} do
      {text, copy} when is_binary(text) and text != "" and copy != false ->
        send_port(state, Protocol.clipboard(:primary, text))
        if copy == :clipboard, do: send_port(state, Protocol.clipboard(:clipboard, text))

      _ ->
        :ok
    end

    %{state | selecting: false}
  end

  defp local_mouse({:mouse, :press, 1, _col, _row, _mods, _}, _id, state) do
    send_port(state, Protocol.paste_primary())
    state
  end

  # Right click: what's selected goes on the clipboard and to the prompt of
  # the pane under the pointer, wherever on the window it was selected. Nothing
  # selected, nothing happens.
  defp local_mouse({:mouse, :press, 2, _col, _row, _mods, _}, id, state) do
    case selected_text(state, id) do
      {pane, text} ->
        send_port(state, Protocol.clipboard(:clipboard, text))
        on_pane(pane, &Screen.clear_selection/1)
        paste_to(state, id, Keymap.paste(text, pane_input(state, id)))

      nil ->
        state
    end
  end

  # On the alternate screen there's no scrollback: the wheel sends arrow
  # keys instead, so less, man and git log scroll (xterm's alternateScroll).
  defp local_mouse({:mouse, :wheel, dir, _col, _row, _mods, _}, id, state) do
    input = pane_input(state, id)

    if pane_value(state, id, :alt_screen, false) and not input.alternate_scroll do
      state
    else
      wheel(dir, id, state)
    end
  end

  defp local_mouse(_event, _id, state), do: state

  # A link comes from whatever printed it, so it only opens if it's the kind
  # of thing a browser or mail app should open. The status shows where it
  # went: text can claim to be one address and link to another.
  defp open_link(state, uri) do
    scheme = uri |> String.split(":", parts: 2) |> hd() |> String.downcase()

    if scheme in @link_schemes do
      send_port(state, Protocol.open_url(uri))
      flash(state, "opening " <> uri)
    else
      flash(state, "not opening a #{scheme} link")
    end
  end

  defp wheel(dir, id, state) do
    if pane_value(state, id, :alt_screen, false) do
      key = if dir == 0, do: Keymap.key(:up), else: Keymap.key(:down)
      bytes = Keymap.to_bytes({:key, key, 0}, pane_input(state, id))
      write_to(state, id, :binary.copy(bytes, state.config.wheel_lines))
    else
      lines = if dir == 0, do: state.config.wheel_lines, else: -state.config.wheel_lines
      on_pane(id, &Screen.scroll(&1, {:lines, lines}))
      if id == state.active, do: %{state | view_moved: true}, else: state
    end
  end

  # The pane under the pointer first, then the others shown.
  defp selected_text(state, id) do
    [id | Compose.ids(state.compose) -- [id]]
    |> Enum.find_value(fn pane ->
      case on_pane(pane, &Screen.selection_text/1) do
        text when is_binary(text) and text != "" -> {pane, text}
        _ -> nil
      end
    end)
  end

  # Typing in the focused pane may go to a broadcast group; another pane is
  # just that pane.
  defp paste_to(%{active: id} = state, id, bytes), do: input(state, bytes)
  defp paste_to(state, id, bytes), do: write_to(state, id, bytes)

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
        catch_exit(fn -> Tabs.rename(state.desk_tabs, state.active_tab, name) end)
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

  defp on_pane(id, fun), do: catch_exit(fn -> fun.(id) end)

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

  defp run(action, state) when action in [:split_right, :split_down] do
    case catch_exit(fn -> Tabs.split(state.desk_tabs, direction(action)) end) do
      {:error, :too_small} -> flash(state, "no room to split this pane")
      _ -> state
    end
  end

  defp run(action, state) when action in [:focus_left, :focus_right, :focus_up, :focus_down] do
    catch_exit(fn -> Tabs.focus(state.desk_tabs, direction(action)) end)
    state
  end

  defp run(action, state)
       when action in [:resize_left, :resize_right, :resize_up, :resize_down] do
    catch_exit(fn -> Tabs.resize_pane(state.desk_tabs, direction(action)) end)
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
    {_id, title} = Enum.find(state.tabs, {nil, ""}, fn {id, _} -> id == state.active_tab end)
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

  defp run(action, state) when action in [:prev_prompt, :next_prompt] do
    direction = if action == :prev_prompt, do: :older, else: :newer
    on_screen(state, &Screen.jump_prompt(&1, direction))
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

  # Open the config file, creating it from the example first: in a new
  # tab running $VISUAL (or $EDITOR), the editor you'd use in a terminal;
  # the tab closes when it exits. Without one, in the app the desktop uses
  # for the file, which the renderer opens (SDL_OpenURL): it runs in the
  # user's session, with the right display.
  defp run(:open_config, state) do
    path = Config.path()

    unless File.exists?(path) do
      File.mkdir_p!(Path.dirname(path))
      File.cp!(Path.join(:code.priv_dir(:guiltty), "config.example.exs"), path)
    end

    with {program, args} <- editor(System.get_env()),
         {:ok, _id} <-
           catch_exit(fn ->
             Tabs.new_tab(state.desk_tabs, shell: program, args: args ++ [path])
           end) do
      state
    else
      _ -> tap(state, &send_port(&1, Protocol.open_url("file://" <> path)))
    end
  end

  defp run(:cheatsheet, state), do: open_cheatsheet(state, 0)

  defp run(:ai, %{active: nil} = state), do: state

  defp run(:ai, %{config: %{ai: %{command: nil}}} = state) do
    flash(state, ~s(no AI tool set: add ai: [command: "..."] to your config), 6_000)
  end

  defp run(:ai, state) do
    selected = selected_text(state, state.active)
    if selected, do: on_pane(elem(selected, 0), &Screen.clear_selection/1)
    text = if selected, do: elem(selected, 1)
    key = ai_key(state)
    pane = Map.get(state.ai_panes, key)

    cond do
      not ai_alive?(pane) -> open_ai(state, key, text)
      pane == state.active and text == nil -> leave_ai(state)
      true -> state |> enter_ai(pane) |> send_to_ai(pane, text)
    end
  end

  defp run(:broadcast, %{active: nil} = state), do: state

  # A tab running ssh joins at once. A local one only on a second press:
  # joining a local tab must be on purpose, so a tab whose ssh just died
  # can't slip in by accident.
  defp run(:broadcast, state) do
    programs = state.config.broadcast_programs
    local? = state.confirm_local == state.active_tab

    case catch_exit(fn ->
           Tabs.toggle_broadcast(state.desk_tabs, state.active_tab, programs, local: local?)
         end) do
      {:error, {:not_allowed, program}} ->
        state = %{state | confirm_local: state.active_tab}
        flash(state, "this tab is local (#{program}): Ctrl+Shift+B again adds it as a local tab")

      _ ->
        update_status(%{state | confirm_local: nil, flash: nil})
    end
  end

  defp run(:lock_tab, state) do
    if state.active_tab,
      do: catch_exit(fn -> Tabs.toggle_lock(state.desk_tabs, state.active_tab) end)

    state
  end

  defp run(:zoom_in, state), do: zoom(state, state.zoom + 1)
  defp run(:zoom_out, state), do: zoom(state, state.zoom - 1)
  defp run(:zoom_reset, state), do: zoom(state, 0)

  defp run(_unknown, state), do: state

  ## The AI key

  # Beside you, it's one per tab; in a tab of its own, one per window.
  defp ai_key(%{config: %{ai: %{position: :tab}}}), do: :tab
  defp ai_key(state), do: state.active_tab

  defp ai_alive?(nil), do: false
  defp ai_alive?(pane), do: GenServer.whereis(Session.via(pane, :pty)) != nil

  defp open_ai(state, key, text) do
    with [program | args] <- OptionParser.split(state.config.ai.command),
         path when is_binary(path) <- System.find_executable(program) do
      came_from = {state.active_tab, state.active}

      case open_ai_session(state, path, args) do
        {:ok, pane} ->
          state = %{
            state
            | ai_panes: Map.put(state.ai_panes, key, pane),
              ai_return: came_from
          }

          wait_to_send(state, pane, text)

        _ ->
          flash(state, "couldn't open #{program}")
      end
    else
      [] ->
        flash(state, "the ai setting has no command")

      nil ->
        flash(
          state,
          "#{state.config.ai.command}: not found. Try its full path in the ai setting",
          6_000
        )
    end
  end

  defp open_ai_session(state, path, args) do
    opts = [shell: path, args: args]

    case state.config.ai.position do
      :tab ->
        catch_exit(fn -> Tabs.new_tab(state.desk_tabs, opts) end)

      direction ->
        case catch_exit(fn -> Tabs.split(state.desk_tabs, direction, opts) end) do
          # No room for a pane: a tab is better than nothing.
          {:error, :too_small} -> catch_exit(fn -> Tabs.new_tab(state.desk_tabs, opts) end)
          result -> result
        end
    end
  end

  defp enter_ai(state, pane) do
    state = %{state | ai_return: {state.active_tab, state.active}}
    go_to(state, pane)
  end

  defp leave_ai(%{ai_return: {_tab, pane}} = state) when pane != nil do
    if ai_alive?(pane), do: go_to(state, pane), else: state
  end

  defp leave_ai(state), do: state

  # A pane of this tab, or the tab it's in.
  defp go_to(state, pane) do
    case Enum.find_index(state.tabs, fn {tab, _} -> pane in Map.get(state.members, tab, [tab]) end) do
      nil ->
        state

      index ->
        {tab, _} = Enum.at(state.tabs, index)
        if tab != state.active_tab, do: switch(state, index)
        catch_exit(fn -> Tabs.focus(state.desk_tabs, {:pane, pane}) end)
        state
    end
  end

  # A tool that's just starting hasn't said yet whether it takes bracketed paste.
  defp wait_to_send(state, _pane, nil), do: state

  defp wait_to_send(state, pane, text) do
    Process.send_after(self(), {:ai_paste_late, pane}, @ai_paste_ms)
    %{state | ai_paste: %{pane: pane, text: text}}
  end

  defp send_to_ai(state, _pane, nil), do: state

  defp send_to_ai(state, pane, text),
    do: deliver_ai_paste(%{state | ai_paste: %{pane: pane, text: text}})

  # As soon as the tool asks for bracketed paste, which most do as they're ready.
  defp ready_ai_paste(%{ai_paste: %{pane: pane}} = state) do
    if pane_value(state, pane, :input, @default_input).bracketed_paste,
      do: deliver_ai_paste(state),
      else: state
  end

  defp ready_ai_paste(state), do: state

  # Never to the broadcast group, and never with an Enter. A program that doesn't
  # take bracketed paste would read a line break as Enter, so it gets one line.
  defp deliver_ai_paste(%{ai_paste: %{pane: pane, text: text}} = state) do
    input = pane_value(state, pane, :input, @default_input)
    text = if input.bracketed_paste, do: text, else: String.replace(text, ~r/\s*\R\s*/, " ")
    catch_exit(fn -> Pty.write(pane, Keymap.paste(text, input)) end)
    %{state | ai_paste: nil}
  end

  # :split_right is :right, :focus_up is :up...
  defp direction(action),
    do:
      action |> Atom.to_string() |> String.split("_") |> List.last() |> String.to_existing_atom()

  @doc false
  # The editor to open the config with: $VISUAL, else $EDITOR, split like
  # a shell would ("emacs -nw" is emacs with -nw), as `{path, args}`, or
  # nil when neither is set or the program isn't installed.
  def editor(env) do
    with value when is_binary(value) <-
           Enum.find([env["VISUAL"], env["EDITOR"]], &(&1 not in [nil, ""])),
         [program | args] <- OptionParser.split(value),
         path when is_binary(path) <- System.find_executable(program) do
      {path, args}
    else
      _ -> nil
    end
  end

  ## The cheatsheet
  #
  # Guiltty.Cheatsheet draws every key into rows, from the config. Instead
  # of the tab's screen, the Window sends a screenful of those rows; on
  # closing, the Screen sends all of its rows again.

  defp open_cheatsheet(state, top) do
    {cols, _rows} = state.size
    # The tab's images hide under it; closing it subscribes again, and
    # the Screen sends them back.
    send_port(state, Protocol.placements(state.size, []))
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
    resubscribe(state)
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
    state = %{
      state
      | locked: info.locked,
        group: info.group,
        lost: MapSet.to_list(info.lost),
        members: Map.get(info, :members, %{})
    }

    marks = Map.get(info, :marks, %{})

    titles =
      Enum.map(tabs, fn {id, title} ->
        title = if title == "", do: "shell", else: title
        title = if MapSet.member?(state.locked, id), do: "🔒 " <> title, else: title
        title = broadcast_marker(state, id) <> title

        case marks[id] do
          :bell -> "🔔 " <> title
          :activity -> "● " <> title
          nil -> title
        end
      end)

    index = Enum.find_index(tabs, fn {id, _} -> id == active end) || 0
    send_port(state, Protocol.tabs(titles, index))

    %{state | tabs: tabs}
    |> show_panes(active, info)
    |> update_status()
  end

  # A tab's panes in the broadcast group: ⚠ if one lost its connection,
  # 🏠 if they're all local, 📡 otherwise.
  defp broadcast_marker(state, tab) do
    panes = Map.get(state.members, tab, [tab])
    grouped = Enum.filter(panes, &Map.has_key?(state.group, &1))

    cond do
      Enum.any?(panes, &(&1 in state.lost)) -> "⚠ "
      grouped == [] -> ""
      Enum.all?(grouped, &(state.group[&1] == :local)) -> "🏠 "
      true -> "📡 "
    end
  end

  # A new tab, or new panes or sizes in it: a new compose, and every pane
  # viewed again (each sends all its rows). Only the focus moved: the same
  # rows, redrawn with the other pane's separators lit and its cursor.
  defp show_panes(state, nil, _info), do: leave_tab(state)

  defp show_panes(state, tab, info) do
    panes = info.panes
    order = Map.get(state.members, tab, Map.keys(panes.rects))
    key = {tab, panes.rects, info.size, order}

    cond do
      key != state.layout_key -> new_layout(state, tab, panes, order, info.size, key)
      panes.focus != state.active -> refocus(state, panes)
      true -> state
    end
  end

  defp new_layout(state, tab, panes, order, size, key) do
    switched? = tab != state.active_tab
    if switched? and state.focused, do: report_focus(state, state.active, false)
    state = if switched?, do: leave_tab(state), else: state
    state = if switched? and state.focused, do: %{state | focus_pending: true}, else: state
    compose = Compose.new(size, panes, order, state.cell_pixels, pane_look(state.config))
    gone = if state.compose, do: Compose.ids(state.compose) -- Compose.ids(compose), else: []
    state = Enum.reduce(gone, state, &unview(&2, &1))

    state = %{
      state
      | compose: compose,
        panes: panes,
        layout_key: key,
        active_tab: tab,
        dirty: MapSet.new(),
        full: true
    }

    state = Enum.reduce(Compose.ids(compose), state, &view(&2, &1))
    state |> focus_on(panes.focus) |> pull()
  end

  defp refocus(state, panes) do
    if state.search, do: on_screen(state, &Screen.end_search/1)
    compose = Compose.refocus(state.compose, panes.focus, panes.separators)

    if state.focused do
      report_focus(state, state.active, false)
      report_focus(state, panes.focus, true)
    end

    %{state | compose: compose, panes: panes, search: nil, selecting: false, full: true}
    |> focus_on(panes.focus)
    |> pull()
  end

  # Leaving a tab: what was going on in it (a search, a rename, the
  # cheatsheet) ends, and its panes are no longer viewed.
  defp leave_tab(state) do
    if state.search, do: on_screen(state, &Screen.end_search/1)

    %{
      unview_all(state)
      | cheatsheet: nil,
        active: nil,
        active_tab: nil,
        compose: nil,
        panes: nil,
        layout_key: nil,
        dirty: MapSet.new(),
        pending: false,
        title: nil,
        search: nil,
        rename: nil,
        confirm_close: nil,
        selecting: false,
        mouse_pane: nil
    }
  end

  # The focused pane is what the window shows as its own: its input
  # modes, title, scroll position.
  defp focus_on(state, id) do
    p = Map.get(state.pane_state, id, %{})

    %{
      state
      | active: id,
        input: Map.get(p, :input, @default_input),
        alt_screen: Map.get(p, :alt_screen, false),
        scroll: Map.get(p, :scroll, 0),
        scrollback: Map.get(p, :scrollback, 0),
        confirm_close: nil
    }
  end

  defp shown?(%{compose: nil}, _id), do: false
  defp shown?(state, id), do: id in Compose.ids(state.compose)

  # View a pane's Screen and monitor it. It answers with
  # {:screen_dirty, id}; if it isn't running right now (mid-restart), try
  # again shortly.
  defp view(state, id) do
    state = unmonitor(state, id)

    with pid when is_pid(pid) <- GenServer.whereis(Session.via(id, :screen)),
         ref = Process.monitor(pid),
         :ok <- catch_exit(fn -> Screen.subscribe(id, self()) end) do
      %{state | screen_refs: Map.put(state.screen_refs, ref, id)}
    else
      _ ->
        Process.send_after(self(), {:view, id}, @resubscribe_ms)
        state
    end
  end

  defp unview(state, id) do
    catch_exit(fn -> Screen.unsubscribe(id, self()) end)
    %{unmonitor(state, id) | pane_state: Map.delete(state.pane_state, id)}
  end

  defp unview_all(state) do
    ids = state.screen_refs |> Map.values() |> Enum.uniq()
    Enum.reduce(ids, state, &unview(&2, &1))
  end

  defp unmonitor(state, id) do
    {mine, others} = Enum.split_with(state.screen_refs, fn {_ref, pane} -> pane == id end)
    for {ref, _} <- mine, do: Process.demonitor(ref, [:flush])
    %{state | screen_refs: Map.new(others)}
  end

  # Every shown pane sends all its rows again (a new theme, the cheatsheet
  # closing): subscribing again is how a Screen is asked for that.
  defp resubscribe(%{compose: nil}), do: :ok

  defp resubscribe(state),
    do:
      for(
        id <- Compose.ids(state.compose),
        do: catch_exit(fn -> Screen.subscribe(id, self()) end)
      )

  defp pane_input(state, id), do: pane_value(state, id, :input, @default_input)

  defp pane_value(state, id, key, default),
    do: state.pane_state |> Map.get(id, %{}) |> Map.get(key, default)

  # Take what's new in every pane that said so, unless the renderer is
  # still drawing the last update; stitch it into one update.
  defp pull(%{awaiting_frame: true} = state), do: %{state | pending: true}
  # The cheatsheet covers the screen; closing it brings every row back.
  defp pull(%{cheatsheet: %{}} = state), do: state
  defp pull(%{compose: nil} = state), do: state

  defp pull(state) do
    {state, changed, clusters, took, graphics?} =
      Enum.reduce(state.dirty, {state, %{}, [], false, false}, fn id,
                                                                  {state, changed, cl, took, g} ->
        case catch_exit(fn -> Screen.take_update(id) end) do
          %{} = update ->
            {compose, rows, defs} = Compose.update(state.compose, id, update)
            pane_state = Map.put(state.pane_state, id, pane_info(update))
            state = %{state | compose: compose, pane_state: pane_state}
            {state, Enum.into(rows, changed), cl ++ defs, true, g or update.graphics != :same}

          _gone ->
            {state, changed, cl, took, g}
        end
      end)

    state = %{state | dirty: MapSet.new()}

    if took or state.full do
      send_update(state, changed, clusters, graphics?)
    else
      state
    end
  end

  defp send_update(state, changed, clusters, graphics?) do
    c = state.compose
    rows = if state.full, do: Compose.all_rows(c), else: changed |> Map.to_list() |> Enum.sort()

    state =
      if graphics? or state.full,
        do: show_graphics(state, %{graphics: Compose.graphics(c), size: c.size}),
        else: state

    p = Map.get(state.pane_state, state.active, %{})
    # The program's cursor shape if it set one, otherwise the user's.
    default = {state.config.cursor.style, state.config.cursor.blink}
    {shape, blink} = Map.get(p, :cursor_style) || default
    # Mode 12 has the last word on blinking.
    blink = if Map.get(p, :cursor_blink) == nil, do: blink, else: p.cursor_blink
    state = show_cursor_color(state, Map.get(p, :cursor_color))

    send_port(
      state,
      Protocol.rows(%{
        size: c.size,
        rows: rows,
        clusters: clusters,
        cursor: Compose.cursor(c, state.active, Map.get(p, :cursor, {0, 0})),
        cursor_visible: Map.get(p, :cursor_visible, false),
        cursor_style: {shape, blink}
      })
    )

    title = Map.get(p, :title)

    if title != nil and title != state.title,
      do: send_port(state, Protocol.title(window_title(title)))

    state = state |> report_pending_focus(p) |> ready_ai_paste()

    %{
      focus_on(state, state.active)
      | awaiting_frame: true,
        pending: false,
        full: false,
        title: title || state.title
    }
    |> update_status()
  end

  defp report_pending_focus(%{focus_pending: true} = state, %{input: _}) do
    report_focus(state, state.active, true)
    %{state | focus_pending: false}
  end

  defp report_pending_focus(state, _pane), do: state

  defp pane_info(update) do
    Map.take(update, [
      :input,
      :title,
      :alt_screen,
      :scroll,
      :scrollback,
      :cursor,
      :cursor_visible,
      :cursor_style,
      :cursor_blink,
      :cursor_color
    ])
  end

  # OSC 12. There's one cursor drawn, the focused pane's, so its color goes
  # to the renderer with the theme: the rows come again, as with any new theme.
  defp show_cursor_color(%{sent_cursor_color: color} = state, color), do: state

  defp show_cursor_color(state, color) do
    theme = if color, do: %{state.config.theme | cursor: color}, else: state.config.theme
    send_port(state, Protocol.theme(theme))
    resubscribe(state)
    %{state | sent_cursor_color: color}
  end

  # Images: the renderer gets each one it doesn't have yet, forgets those
  # nothing shows any more, then where they go. All before the ROWS, so
  # the frame it draws for them has the images in place.
  defp show_graphics(state, %{graphics: :same}), do: state

  defp show_graphics(state, %{graphics: {placements, images}, size: size}) do
    for {uid, image} <- images,
        not MapSet.member?(state.sent_images, uid),
        do: send_port(state, Protocol.image(uid, image))

    keep = images |> Map.keys() |> MapSet.new()

    for uid <- MapSet.difference(state.sent_images, keep),
        do: send_port(state, Protocol.image_drop(uid))

    send_port(state, Protocol.placements(size, placements))
    %{state | sent_images: keep}
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

  # A lost connection in the broadcast group: say which. Typing goes
  # nowhere until that tab leaves the group (Ctrl+Shift+B on it) or closes.
  # It comes before a config error: that one stays until the file is fixed,
  # and would hide why your keys go nowhere.
  defp status_text(%{lost: [_ | _] = lost} = state) do
    names =
      Enum.map_join(lost, ", ", fn id ->
        index =
          Enum.find_index(state.tabs, fn {tab, _} -> id in Map.get(state.members, tab, [tab]) end)

        host = state.group[id]
        "tab #{(index || 0) + 1}" <> if(host, do: " (#{host})", else: "")
      end)

    # Short, so the tabs stay visible; how to go on is on the cheatsheet.
    {:warning, "⚠ broadcast paused: #{names} disconnected"}
  end

  defp status_text(%{config_error: error}) when is_binary(error),
    do: {:warning, "⚠ " <> error}

  # How many tabs the typing goes to, and how many panes when that's more.
  defp status_text(%{group: group, active: active} = state) when is_map_key(group, active) do
    count =
      Enum.count(state.members, fn {_tab, panes} -> Enum.any?(panes, &is_map_key(group, &1)) end)

    count = max(count, 1)
    panes = map_size(group)
    local = Enum.count(group, fn {_id, host} -> host == :local end)
    tabs = "#{count} tab#{if count == 1, do: "", else: "s"}"
    tabs = if panes > count, do: tabs <> ", #{panes} panes", else: tabs
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
      cursor = state.sent_cursor_color || config.theme.cursor
      send_port(state, Protocol.theme(%{config.theme | cursor: cursor}))
      # The renderer resolved every cell with the old theme: send them all again.
      resubscribe(state)
    end

    old_font = font(state)
    old = state.config
    state = %{state | config: config, bindings: parse_bindings(config.keys)}
    if font(state) != old_font, do: send_port(state, Protocol.font(font(state)))
    if options(config) != options(old), do: send_port(state, Protocol.options(options(config)))
    if tab_style(config) != tab_style(old), do: send_port(state, tab_style(config))

    # A new default cursor shows with the next update, and bold-is-bright
    # changes the colors of rows the renderer already has: ask for every
    # row again.
    if config.cursor != old.cursor or config.bold_is_bright != old.bold_is_bright,
      do: resubscribe(state)

    # The panes' borders: drawn again in the new look.
    state =
      if state.compose && pane_look(config) != pane_look(old),
        do:
          pull(%{state | compose: Compose.restyle(state.compose, pane_look(config)), full: true}),
        else: state

    # The keys on the cheatsheet may have changed.
    if state.cheatsheet, do: open_cheatsheet(state, state.cheatsheet.top), else: state
  end

  defp pane_look(config), do: Compose.look(config.pane_border, config.theme)

  defp tab_style(config),
    do:
      config
      |> Map.get(:tab_style, :flat)
      |> Protocol.tab_style(config.theme)
      |> IO.iodata_to_binary()

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

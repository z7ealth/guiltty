defmodule Guiltty.Config do
  @moduledoc """
  Config as code: `~/.config/guiltty/config.exs` (or `$GUILTTY_CONFIG`) is
  plain Elixir, evaluated on start and again whenever it changes. See
  `priv/config.example.exs`.

  The file's modification time is checked every second. When it changes,
  the file is evaluated in a separate process (a broken config can't take
  this one down), merged over the defaults, and sent to subscribers as
  `{:config, config}`. If it raises or isn't a keyword list, the previous
  config stays: the full error goes to the log, and a one-line version
  (`"config.exs:4: theme: unknown name ..."`) to subscribers as
  `{:config_error, message}`, so the window can show it. It's sent again
  to every new subscriber until a config loads.

  A config is a map:

    * `:theme` - a `Guiltty.Theme`
    * `:font` - `%{family: "monospace", size: 18}`
    * `:keys` - `%{action => [key]}`, see `Guiltty.Keymap.parse_key/1`
    * `:scrollback` - rows each tab keeps (applies to tabs opened after a
      change)
    * `:cursor` - `%{style: :block | :bar | :underline, blink: boolean}`
      (programs can change it while they run, as vim does in insert mode)
    * `:window` - `%{padding: px, columns: n, rows: n, opacity: 0.1..1.0}`;
      `columns` and `rows` are the size of a new window, `opacity` the
      background's (it needs a compositor, and applies to windows opened
      after a change)
    * `:shell` - `%{command: path | nil, args: [binary]}`; nil runs your
      login shell
    * `:working_directory` - `:inherit` (a new tab starts where the active
      tab's shell is), `:home`, or a path
    * `:copy_on_select` - `true` (the primary selection), `:clipboard` (the
      clipboard too) or `false`
    * `:wheel_lines` - rows the mouse wheel scrolls per step
    * `:bold_is_bright` - bold text in the 8 basic colors uses the bright ones
    * `:tab_bar` - `:bottom` (the default) or `:top`
    * `:ligatures` - join `->`, `!=`, `|>` and the like into one symbol,
      when the font has ligatures (JetBrains Mono, Fira Code)
    * `:broadcast_programs` - what a tab must be running to join the
      broadcast group (Ctrl+Shift+B): `["ssh", "mosh-client"]`
    * `:renderer` - `:vulkan` or `:gl`, for windows opened after a change;
      Vulkan falls back to OpenGL by itself when it can't start
  """

  use GenServer

  require Logger

  alias Guiltty.Theme

  @poll_ms 1_000

  @default_keys %{
    new_window: ["ctrl+shift+n"],
    new_tab: ["ctrl+shift+t"],
    close_tab: ["ctrl+shift+w"],
    next_tab: ["ctrl+page_down", "ctrl+tab"],
    prev_tab: ["ctrl+page_up", "ctrl+shift+tab"],
    scroll_page_up: ["shift+page_up"],
    scroll_page_down: ["shift+page_down"],
    scroll_top: ["shift+home"],
    scroll_bottom: ["shift+end"],
    search: ["ctrl+shift+f"],
    copy: ["ctrl+shift+c"],
    zoom_in: ["ctrl+=", "ctrl+shift+="],
    zoom_out: ["ctrl+-"],
    zoom_reset: ["ctrl+0"],
    open_config: ["ctrl+,"],
    cheatsheet: ["ctrl+shift+/"],
    lock_tab: ["ctrl+shift+l"],
    broadcast: ["ctrl+shift+b"]
  }

  @max_scrollback 1_000_000

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "The defaults, used for anything the file doesn't set."
  def defaults do
    %{
      theme: Theme.default(),
      font: %{family: "monospace", size: 18},
      keys: @default_keys,
      scrollback: 10_000,
      cursor: %{style: :block, blink: false},
      window: %{padding: 6, columns: 80, rows: 24, opacity: 1.0},
      shell: %{command: nil, args: []},
      working_directory: :inherit,
      copy_on_select: true,
      wheel_lines: 3,
      bold_is_bright: true,
      tab_bar: :bottom,
      ligatures: true,
      broadcast_programs: ["ssh", "mosh-client"],
      renderer: :vulkan
    }
  end

  @doc "The current config (the defaults if guiltty's config process isn't running)."
  def get do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :get), else: defaults()
  end

  @doc """
  Sends `{:config, config}` to `pid` on every change, and
  `{:config_error, message}` while the file has an error (right away, if
  it has one now).
  """
  def subscribe(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})

  def path, do: System.get_env("GUILTTY_CONFIG") || Path.expand("~/.config/guiltty/config.exs")

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, path())
    state = %{path: path, mtime: nil, config: defaults(), subscribers: MapSet.new(), error: nil}
    {:ok, reload(state), {:continue, :poll}}
  end

  @impl true
  def handle_continue(:poll, state) do
    Process.send_after(self(), :poll, @poll_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state.config, state}

  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    if state.error, do: send(pid, {:config_error, state.error})
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  @impl true
  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, @poll_ms)
    {:noreply, if(mtime(state.path) != state.mtime, do: reload(state), else: state)}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  defp reload(state) do
    mtime = mtime(state.path)

    case mtime && load(state.path) do
      nil ->
        %{state | mtime: mtime}

      {:ok, config} ->
        Logger.info("config: loaded #{state.path}")
        Enum.each(state.subscribers, &send(&1, {:config, config}))
        %{state | mtime: mtime, config: config, error: nil}

      {:error, reason} ->
        Logger.error("config: #{state.path} not applied: #{reason}")
        error = short_error(state.path, reason)
        Enum.each(state.subscribers, &send(&1, {:config_error, error}))
        %{state | mtime: mtime, error: error}
    end
  end

  # One line for the window: "config.exs:4: what's wrong". Errors with a
  # place in the file already start with "path:line:"; the others get the
  # file's name in front.
  defp short_error(path, reason) do
    first = reason |> String.split("\n", trim: true) |> List.first("") |> String.trim()
    name = Path.basename(path)

    if String.starts_with?(first, path),
      do: String.replace_prefix(first, path, name),
      else: "#{name}: #{first}"
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime
      _ -> nil
    end
  end

  @doc false
  # Evaluates a config file and merges it over the defaults.
  def load(path) do
    # Monitored, not linked: whatever the file does, this process survives.
    parent = self()
    tag = make_ref()

    {pid, ref} =
      spawn_monitor(fn ->
        result =
          try do
            {:ok, path |> Code.eval_file() |> elem(0)}
          rescue
            e -> {:raised, e, __STACKTRACE__}
          end

        send(parent, {tag, result})
      end)

    receive do
      {^tag, {:ok, settings}} ->
        Process.demonitor(ref, [:flush])

        if Keyword.keyword?(settings),
          do: build(settings),
          else: {:error, "expected a keyword list, got #{inspect(settings, limit: 5)}"}

      {^tag, {:raised, e, stacktrace}} ->
        Process.demonitor(ref, [:flush])
        {:error, describe(e, stacktrace, path)}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, Exception.format_exit(reason)}
    after
      5_000 ->
        Process.exit(pid, :kill)
        {:error, "took more than 5 seconds to evaluate"}
    end
  end

  # "path:line: message", with the line the problem is on: syntax errors
  # carry it, runtime errors have it in the stacktrace.
  defp describe(e, stacktrace, path) do
    message = e |> Exception.message() |> String.split("\n", trim: true) |> List.first("")
    message = Map.get(e, :description) || message

    line =
      Map.get(e, :line) ||
        Enum.find_value(stacktrace, fn {_m, _f, _a, info} ->
          # Stacktraces name files relative to the current directory.
          if info[:file] && Path.expand(to_string(info[:file])) == Path.expand(path),
            do: info[:line]
        end)

    if line, do: "#{path}:#{line}: #{message}", else: "#{path}: #{message}"
  end

  # The names each section accepts. A name that isn't here is almost always
  # a typo, which would otherwise be ignored without a word.
  defp known_names(d) do
    %{
      nil => Map.keys(d),
      font: Map.keys(d.font),
      theme: [:name, :fg, :bg, :cursor, :ansi],
      cursor: Map.keys(d.cursor),
      window: Map.keys(d.window),
      shell: Map.keys(d.shell),
      keys: Map.keys(d.keys)
    }
  end

  # Every name in the file must be one guiltty knows, in every section
  # that's a keyword list.
  defp check_names(settings, d) do
    known = known_names(d)

    sections =
      [{nil, settings}] ++
        for {section, opts} <- settings,
            Map.has_key?(known, section),
            Keyword.keyword?(opts),
            do: {section, opts}

    Enum.find_value(sections, :ok, fn {section, opts} ->
      case Enum.find(Keyword.keys(opts), &(&1 not in known[section])) do
        nil -> nil
        name -> {:error, unknown_name(section, name, known[section])}
      end
    end)
  end

  defp unknown_name(section, name, known) do
    where = if section, do: "#{section}: unknown name", else: "unknown setting"

    suggestion =
      known
      |> Enum.map(&{&1, String.jaro_distance(to_string(&1), to_string(name))})
      |> Enum.max_by(&elem(&1, 1), fn -> {nil, 0} end)

    case suggestion do
      {best, score} when score >= 0.8 ->
        "#{where} #{inspect(name)} (did you mean #{inspect(best)}?)"

      _ ->
        "#{where} #{inspect(name)}"
    end
  end

  # A value of an unexpected shape (font: :big) can make a check raise.
  # That must be a message, never a crash of this process: it would take
  # the config down with it.
  defp build(settings) do
    with :ok <- check_names(settings, defaults()), do: build_checked(settings)
  rescue
    e -> {:error, "unexpected value: #{Exception.message(e) |> String.split("\n") |> hd()}"}
  end

  defp build_checked(settings) do
    d = defaults()
    get = &Keyword.get(settings, &1, &2)

    with {:ok, theme} <- theme(get.(:theme, []), d.theme),
         {:ok, font} <- font(get.(:font, []), d.font),
         {:ok, keys} <- keys(get.(:keys, []), d.keys),
         {:ok, scrollback} <- scrollback(get.(:scrollback, d.scrollback)),
         {:ok, cursor} <- cursor(get.(:cursor, []), d.cursor),
         {:ok, window} <- window(get.(:window, []), d.window),
         {:ok, shell} <- shell(get.(:shell, []), d.shell),
         {:ok, dir} <- working_directory(get.(:working_directory, d.working_directory)),
         {:ok, copy} <-
           one_of(:copy_on_select, get.(:copy_on_select, true), [true, false, :clipboard]),
         {:ok, wheel} <- number(:wheel_lines, get.(:wheel_lines, d.wheel_lines), 1..50),
         {:ok, bright} <- one_of(:bold_is_bright, get.(:bold_is_bright, true), [true, false]),
         {:ok, tab_bar} <- one_of(:tab_bar, get.(:tab_bar, d.tab_bar), [:top, :bottom]),
         {:ok, ligatures} <- one_of(:ligatures, get.(:ligatures, d.ligatures), [true, false]),
         {:ok, programs} <- programs(get.(:broadcast_programs, d.broadcast_programs)),
         {:ok, renderer} <- one_of(:renderer, get.(:renderer, d.renderer), [:vulkan, :gl]) do
      {:ok,
       %{
         theme: theme,
         font: font,
         keys: keys,
         scrollback: scrollback,
         cursor: cursor,
         window: window,
         shell: shell,
         working_directory: dir,
         copy_on_select: copy,
         wheel_lines: wheel,
         bold_is_bright: bright,
         tab_bar: tab_bar,
         ligatures: ligatures,
         broadcast_programs: programs,
         renderer: renderer
       }}
    end
  end

  defp cursor(opts, d) when is_list(opts) do
    with {:ok, style} <-
           one_of(:"cursor style", Keyword.get(opts, :style, d.style), [:block, :bar, :underline]),
         {:ok, blink} <-
           one_of(:"cursor blink", Keyword.get(opts, :blink, d.blink), [true, false]) do
      {:ok, %{style: style, blink: blink}}
    end
  end

  defp cursor(_, _), do: {:error, "cursor: expected a keyword list"}

  defp window(opts, d) when is_list(opts) do
    opacity = Keyword.get(opts, :opacity, d.opacity)

    with {:ok, padding} <-
           number(:"window padding", Keyword.get(opts, :padding, d.padding), 0..100),
         {:ok, columns} <-
           number(:"window columns", Keyword.get(opts, :columns, d.columns), 10..1000),
         {:ok, rows} <- number(:"window rows", Keyword.get(opts, :rows, d.rows), 3..1000),
         true <- is_number(opacity) and opacity >= 0.1 and opacity <= 1.0 do
      {:ok, %{padding: padding, columns: columns, rows: rows, opacity: opacity / 1}}
    else
      false -> {:error, "window opacity: expected a number from 0.1 to 1.0"}
      error -> error
    end
  end

  defp window(_, _), do: {:error, "window: expected a keyword list"}

  defp shell(opts, d) when is_list(opts) do
    command = Keyword.get(opts, :command, d.command)
    args = Keyword.get(opts, :args, d.args)

    if (command == nil or (is_binary(command) and command != "")) and is_list(args) and
         Enum.all?(args, &is_binary/1),
       do: {:ok, %{command: command, args: args}},
       else: {:error, "shell: expected command: \"/path\" and args: [strings]"}
  end

  defp shell(_, _), do: {:error, "shell: expected a keyword list"}

  defp working_directory(dir) when dir in [:inherit, :home], do: {:ok, dir}
  defp working_directory("/" <> _ = dir), do: {:ok, dir}
  defp working_directory("~" <> _ = dir), do: {:ok, Path.expand(dir)}

  defp working_directory(other),
    do: {:error, "working_directory: expected :inherit, :home or a path, got #{inspect(other)}"}

  # Program names as /proc shows them (at most 15 characters: comm(5)).
  defp programs([_ | _] = names) do
    if Enum.all?(names, &(is_binary(&1) and &1 != "")),
      do: {:ok, names},
      else: {:error, "broadcast_programs: expected program names, like [\"ssh\"]"}
  end

  defp programs(_), do: {:error, "broadcast_programs: expected a list of program names"}

  defp one_of(name, value, allowed) do
    if value in allowed,
      do: {:ok, value},
      else: {:error, "#{name}: expected one of #{inspect(allowed)}, got #{inspect(value)}"}
  end

  defp number(_name, n, range) when is_integer(n) and n >= range.first and n <= range.last,
    do: {:ok, n}

  defp number(name, n, range),
    do:
      {:error,
       "#{name}: expected a number from #{range.first} to #{range.last}, got #{inspect(n)}"}

  defp scrollback(n) when is_integer(n) and n in 0..@max_scrollback, do: {:ok, n}

  defp scrollback(_),
    do: {:error, "scrollback: expected a number of rows from 0 to #{@max_scrollback}"}

  # A theme is a name ("dracula"), or a keyword list of colors, which may
  # start from a named theme with `name:`.
  defp theme(name, _default) when is_binary(name), do: theme([name: name], nil)

  defp theme(opts, default) when is_list(opts) do
    case Keyword.get(opts, :name) do
      nil -> colors(opts, default)
      name -> with {:ok, base} <- named_theme(name), do: colors(opts, base)
    end
  end

  defp theme(other, _default),
    do: {:error, "theme: expected a name or a keyword list, got #{inspect(other)}"}

  defp named_theme(name) do
    case Theme.named(name) do
      {:ok, theme} ->
        {:ok, theme}

      :error ->
        {:error,
         "theme: unknown name #{inspect(name)}, try one of #{Enum.join(Theme.names(), ", ")}"}
    end
  end

  defp colors(opts, default) do
    with {:ok, fg} <- color(opts[:fg], default.fg),
         {:ok, bg} <- color(opts[:bg], default.bg),
         {:ok, cursor} <- color(opts[:cursor], default.cursor),
         {:ok, ansi} <- ansi(opts[:ansi], default.ansi) do
      {:ok, %Theme{fg: fg, bg: bg, cursor: cursor, ansi: ansi}}
    end
  end

  defp ansi(nil, default), do: {:ok, default}

  defp ansi(list, _default) when is_list(list) and length(list) == 16 do
    Enum.reduce_while(list, {:ok, []}, fn hex, {:ok, acc} ->
      case color(hex, nil) do
        {:ok, rgb} -> {:cont, {:ok, acc ++ [rgb]}}
        error -> {:halt, error}
      end
    end)
  end

  defp ansi(_other, _default), do: {:error, "theme ansi: expected 16 colors"}

  defp color(nil, default), do: {:ok, default}

  defp color("#" <> <<r::binary-size(2), g::binary-size(2), b::binary-size(2)>> = hex, _default) do
    with {r, ""} <- Integer.parse(r, 16),
         {g, ""} <- Integer.parse(g, 16),
         {b, ""} <- Integer.parse(b, 16) do
      {:ok, {r, g, b}}
    else
      _ -> {:error, "bad color #{hex}"}
    end
  end

  defp color(other, _default), do: {:error, "bad color #{inspect(other)}, expected \"#rrggbb\""}

  defp font(opts, _default) when not is_list(opts),
    do: {:error, "font: expected a keyword list, like [family: \"monospace\", size: 18]"}

  defp font(opts, default) do
    family = Keyword.get(opts, :family, default.family)
    size = Keyword.get(opts, :size, default.size)

    if is_binary(family) and family != "" and is_integer(size) and size in 6..96,
      do: {:ok, %{family: family, size: size}},
      else: {:error, "font: expected a family name and a size from 6 to 96"}
  end

  defp keys(opts, _defaults) when not is_list(opts),
    do: {:error, "keys: expected a keyword list, like [new_tab: [\"ctrl+shift+t\"]]"}

  defp keys(opts, defaults) do
    merged = Map.merge(defaults, Map.new(opts))

    case Enum.find(merged, fn {_action, keys} ->
           not (is_list(keys) and Enum.all?(keys, &is_binary/1))
         end) do
      nil -> {:ok, merged}
      {action, _} -> {:error, "keys #{action}: expected a list of strings"}
    end
  end
end

defmodule Guiltty.Config do
  @moduledoc """
  Config as code: `~/.config/guiltty/config.exs` (or `$GUILTTY_CONFIG`) is
  plain Elixir, evaluated on start and again whenever it changes. See
  `priv/config.example.exs`.

  The file's modification time is checked every second. When it changes,
  the file is evaluated in a separate process (a broken config can't take
  this one down), merged over the defaults, and sent to subscribers as
  `{:config, config}`. If it raises or isn't a keyword list, the error is
  logged and the previous config stays.

  A config is a map:

    * `:theme` - a `Guiltty.Theme`
    * `:font` - `%{family: "monospace", size: 18}`
    * `:keys` - `%{action => [key]}`, see `Guiltty.Keymap.parse_key/1`
  """

  use GenServer

  require Logger

  alias Guiltty.Theme

  @poll_ms 1_000

  @default_keys %{
    new_tab: ["ctrl+shift+t"],
    close_tab: ["ctrl+shift+w"],
    next_tab: ["ctrl+page_down", "ctrl+tab"],
    prev_tab: ["ctrl+page_up", "ctrl+shift+tab"]
  }

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "The defaults, used for anything the file doesn't set."
  def defaults,
    do: %{theme: Theme.default(), font: %{family: "monospace", size: 18}, keys: @default_keys}

  @doc "The current config (the defaults if guiltty's config process isn't running)."
  def get do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :get), else: defaults()
  end

  @doc "Sends `{:config, config}` to `pid` on every change."
  def subscribe(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})

  def path, do: System.get_env("GUILTTY_CONFIG") || Path.expand("~/.config/guiltty/config.exs")

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, path())
    state = %{path: path, mtime: nil, config: defaults(), subscribers: MapSet.new()}
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
        %{state | mtime: mtime, config: config}

      {:error, reason} ->
        Logger.error("config: #{state.path} not applied: #{reason}")
        %{state | mtime: mtime}
    end
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
    {pid, ref} = spawn_monitor(fn -> send(parent, {tag, path |> Code.eval_file() |> elem(0)}) end)

    receive do
      {^tag, settings} ->
        Process.demonitor(ref, [:flush])

        if Keyword.keyword?(settings),
          do: build(settings),
          else: {:error, "expected a keyword list, got #{inspect(settings, limit: 5)}"}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, Exception.format_exit(reason)}
    after
      5_000 ->
        Process.exit(pid, :kill)
        {:error, "took more than 5 seconds to evaluate"}
    end
  end

  defp build(settings) do
    defaults = defaults()

    with {:ok, theme} <- theme(Keyword.get(settings, :theme, []), defaults.theme),
         {:ok, font} <- font(Keyword.get(settings, :font, []), defaults.font),
         {:ok, keys} <- keys(Keyword.get(settings, :keys, []), defaults.keys) do
      {:ok, %{theme: theme, font: font, keys: keys}}
    end
  end

  defp theme(opts, default) do
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

  defp font(opts, default) do
    family = Keyword.get(opts, :family, default.family)
    size = Keyword.get(opts, :size, default.size)

    if is_binary(family) and family != "" and is_integer(size) and size in 6..96,
      do: {:ok, %{family: family, size: size}},
      else: {:error, "font: expected a family name and a size from 6 to 96"}
  end

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

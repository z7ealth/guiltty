defmodule Guiltty.Window do
  @moduledoc """
  Owns the renderer port: starts the renderer, forwards screen updates to
  it, and turns its key events into bytes for the shell.

  The renderer is a separate OS process, so if it crashes only this process
  notices. When the user closes the window the renderer exits with status 0,
  and this process stops; it's significant, so the application stops too.
  """

  use GenServer, restart: :transient

  require Logger

  alias Guiltty.Keymap
  alias Guiltty.Session.{Pty, Screen}
  alias Guiltty.Window.Protocol

  @hello_timeout 5_000

  @doc """
  Options: `:session` (required), `:renderer` (a binary in priv/), `:env`
  (extra environment for the renderer, as `[{charlist, charlist}]`) and
  `:name` (defaults to `Guiltty.Window`; `false` for none).
  """
  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      false -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    session = Keyword.fetch!(opts, :session)
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

    state = %{
      port: port,
      session: session,
      cols: opts[:cols] || 80,
      rows: opts[:rows] || 24,
      ready: false
    }

    {:ok, state, @hello_timeout}
  end

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

  def handle_info({:screen_update, _id, rows, cursor}, state) do
    Port.command(state.port, Protocol.rows(rows, cursor))
    {:noreply, state}
  end

  def handle_info(:timeout, state), do: {:stop, :no_hello_from_renderer, state}

  defp handle_event({:hello, version, backend}, state) do
    if version == Protocol.version() do
      Logger.debug("window: renderer #{backend} speaks protocol #{version}")
      Port.command(state.port, Protocol.setup(state.cols, state.rows))
      # The screen answers with every row, then sends changes as they happen.
      :ok = Screen.subscribe(state.session, self())
      {:noreply, %{state | ready: true}}
    else
      {:stop, {:protocol_mismatch, renderer: version, window: Protocol.version()}, state}
    end
  end

  defp handle_event(event, state) do
    case Keymap.to_bytes(event) do
      nil -> :ok
      bytes -> Pty.write(state.session, bytes)
    end

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    # Closing stdin tells the renderer to quit.
    if Port.info(port), do: Port.close(port)
    :ok
  end

  def terminate(_reason, _state), do: :ok
end

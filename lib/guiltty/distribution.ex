defmodule Guiltty.Distribution do
  @moduledoc """
  Gives the node its name, `guiltty@127.0.0.1`, once that name is free.

  `guiltty stop`, `pid` and `remote` reach a running guiltty over Erlang
  distribution, by that name. The release used to take it at boot
  (`-name`), and failed to start if an old guiltty, still shutting down,
  held it: open a window just as the last one closed, and nothing came.
  Now the release starts without distribution (`rel/env.sh.eex`) and this
  process takes the name, retrying until the old node has let go. Windows
  don't need it, so guiltty works in the meantime. Book chapter 23.

  It does nothing unless `GUILTTY_NODE` is set: in development (`mix
  guiltty`, tests) there's no name to take.
  """

  use GenServer, restart: :transient

  require Logger

  @retry_ms 200
  # 30 s: an old guiltty takes well under a second to go.
  @tries 150

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    case System.get_env("GUILTTY_NODE") do
      nil ->
        :ignore

      name ->
        send(self(), {:start, String.to_atom(name), @tries})
        {:ok, nil}
    end
  end

  @impl true
  def handle_info({:start, name, tries}, state) do
    ensure_epmd()

    # longnames: the name has an address in it (127.0.0.1). The cookie
    # comes from ~/.erlang.cookie (book chapter 20).
    case :net_kernel.start(name, %{name_domain: :longnames}) do
      {:ok, _} ->
        Logger.debug("distribution: this guiltty is #{name}")
        {:stop, :normal, state}

      {:error, reason} when tries > 1 ->
        Logger.debug("distribution: #{name} not yet (#{inspect(reason)}), retrying")
        Process.send_after(self(), {:start, name, tries - 1}, @retry_ms)
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("distribution: gave up on #{name}: #{inspect(reason)}")
        {:stop, :normal, state}
    end
  end

  # A node started at boot with -name starts epmd (the port directory)
  # itself; one that starts distribution later must make sure it runs.
  # It listens where ERL_EPMD_ADDRESS says (127.0.0.1, from env.sh).
  defp ensure_epmd do
    with {:error, _} <- :erl_epmd.names(),
         epmd when is_binary(epmd) <- epmd_path() do
      System.cmd(epmd, ["-daemon"], stderr_to_stdout: true)
    end
  end

  defp epmd_path do
    with bindir when is_binary(bindir) <- System.get_env("BINDIR"),
         path = Path.join(bindir, "epmd"),
         true <- File.exists?(path) do
      path
    else
      _ -> System.find_executable("epmd")
    end
  end
end

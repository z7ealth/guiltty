defmodule Guiltty.Launcher do
  @moduledoc """
  The server half of the `guiltty` command: a Unix socket the C client
  (`c_src/client/guiltty.c`) connects to, to ask for a window. Book
  chapter 23.

      client                                   this process
        connect $XDG_RUNTIME_DIR/guiltty/sock ->
        "guiltty 1 open\\n"                     is it you? (SO_PEERCRED)
        "DISPLAY=:0\\n" ...                     read at most 16 lines, 2 s
        "PWD=/home/me/src\\n"
        "\\n"                                   check every line
                                             <- "ok\\n" or "error: why\\n"

  Only the display variables and the client's folder (`PWD`, where the
  window's first tab starts) are accepted, and only one request: open a
  window (`Guiltty.Lifeline.open/1`, so a closed window that kept locked
  tabs comes back first). Anything else gets an error and the connection
  closes. Each connection is served in its own process, so a slow or
  broken client never holds up another.

  While guiltty is shutting down (`Guiltty.Lifeline` is gone), the answer
  is "error: shutting down": the client waits and asks again, and once
  this socket closes, starts a new guiltty.
  """

  use GenServer

  require Logger

  # Which protocol the client speaks: a client and a server of different
  # versions refuse each other cleanly.
  @version 1
  @open_request "guiltty #{@version} open\n"
  @display_vars ~w(DISPLAY WAYLAND_DISPLAY XAUTHORITY XDG_RUNTIME_DIR)
  @max_lines 16
  @max_line 4096
  @read_timeout 2_000
  # SOL_SOCKET and SO_PEERCRED (socket(7)); the answer is struct ucred:
  # pid, uid, gid, three 32-bit integers.
  @sol_socket 1
  @so_peercred 17

  @doc """
  Options: `:path` (the socket, default `socket_path/0`) and `:window`
  (extra `Guiltty.Window` options for every window it opens; tests use it).
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Where the socket is: `$GUILTTY_SOCKET`, or `$XDG_RUNTIME_DIR/guiltty/sock`
  (a folder only you can open, which systemd makes at login), or
  `/tmp/guiltty-<uid>/sock`. The client looks in the same places.
  """
  def socket_path do
    cond do
      path = System.get_env("GUILTTY_SOCKET") -> path
      dir = System.get_env("XDG_RUNTIME_DIR") -> Path.join([dir, "guiltty", "sock"])
      true -> "/tmp/guiltty-#{my_uid()}/sock"
    end
  end

  @impl true
  def init(opts) do
    path = Keyword.get_lazy(opts, :path, &socket_path/0)

    with :ok <- private_dir(Path.dirname(path)),
         {:ok, listen} <- listen(path) do
      server = self()
      acceptor = spawn_link(fn -> accept(listen, server, Keyword.get(opts, :window, [])) end)
      {:ok, %{listen: listen, path: path, acceptor: acceptor}}
    else
      {:error, reason} ->
        # guiltty works without it: windows just can't be asked for.
        Logger.warning("launcher: no socket at #{path}: #{inspect(reason)}")
        :ignore
    end
  end

  # The socket's folder must be ours alone: whoever can write in it could
  # put their own socket there for the client to talk to.
  defp private_dir(dir) do
    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         {:ok, %{uid: uid, access: :read_write}} <- File.stat(dir),
         true <- uid == my_uid() || {:error, {:not_ours, dir}} do
      :ok
    end
  end

  defp listen(path) do
    # A socket file left by a guiltty that's gone refuses connections:
    # remove it. One that still accepts belongs to a running guiltty
    # (opened twice at once, say): leave it alone.
    case :gen_tcp.connect({:local, path}, 0, [:binary, active: false], 200) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        {:error, :another_guiltty_is_listening}

      {:error, _} ->
        _ = File.rm(path)

        :gen_tcp.listen(0, [
          :binary,
          ifaddr: {:local, path},
          packet: :line,
          packet_size: @max_line,
          active: false,
          backlog: 16
        ])
    end
  end

  defp accept(listen, server, window_opts) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        {:ok, pid} = Task.start(fn -> receive(do: (:go -> serve(socket, window_opts))) end)
        :ok = :gen_tcp.controlling_process(socket, pid)
        send(pid, :go)
        accept(listen, server, window_opts)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        exit({:accept_failed, reason})
    end
  end

  # One connection: check, read, answer, close.
  defp serve(socket, window_opts) do
    reply =
      with :ok <- check_peer(socket),
           {:ok, lines} <- read_lines(socket, []),
           {:ok, request} <- parse_request(lines) do
        open_window(request, window_opts)
      end

    :gen_tcp.send(socket, answer(reply))
    :gen_tcp.close(socket)
  end

  defp answer(:ok), do: "ok\n"
  defp answer({:error, why}), do: "error: #{why}\n"

  # The folder already keeps others out; this says so for every request.
  defp check_peer(socket) do
    case :inet.getopts(socket, [{:raw, @sol_socket, @so_peercred, 12}]) do
      {:ok, [{:raw, _, _, <<_pid::native-32, uid::native-32, _gid::native-32>>}]} ->
        if uid == my_uid(), do: :ok, else: {:error, "not your guiltty"}

      _ ->
        {:error, "can't tell who's asking"}
    end
  end

  defp read_lines(_socket, lines) when length(lines) > @max_lines,
    do: {:error, "request too long"}

  defp read_lines(socket, lines) do
    case :gen_tcp.recv(socket, 0, @read_timeout) do
      {:ok, "\n"} ->
        {:ok, Enum.reverse(lines)}

      # OTP 26 hands out a line over packet_size in pieces, without its
      # line break, where later OTPs return :emsgsize.
      {:ok, line} when binary_part(line, byte_size(line) - 1, 1) != "\n" ->
        {:error, "line too long"}

      {:ok, line} ->
        read_lines(socket, [line | lines])

      {:error, :timeout} ->
        {:error, "request incomplete"}

      {:error, :emsgsize} ->
        {:error, "line too long"}

      {:error, _} ->
        {:error, "request incomplete"}
    end
  end

  @doc """
  Checks a request, its lines without the empty one that ends it. Returns
  `{:ok, %{env: env, cwd: cwd}}`: the display variables as the renderer
  wants them (`[{charlist, charlist}]`), and the client's folder (an
  absolute path) or nil. Or `{:error, why}`. Never raises: whatever a
  client sends is checked here first.
  """
  def parse_request([@open_request | vars]), do: parse_vars(vars, %{env: [], cwd: nil})

  def parse_request(["guiltty " <> rest | _]) when is_binary(rest),
    do: {:error, "this guiltty speaks version #{@version}: update the guiltty command"}

  def parse_request(_), do: {:error, "not a guiltty request"}

  defp parse_vars([], request), do: {:ok, %{request | env: Enum.reverse(request.env)}}

  defp parse_vars([line | rest], request) when is_binary(line) do
    with [name, value] <- String.split(String.trim_trailing(line, "\n"), "=", parts: 2),
         true <- String.valid?(value) and not String.match?(value, ~r/[\x00-\x1f\x7f]/),
         {:ok, request} <- add_var(request, name, value) do
      parse_vars(rest, request)
    else
      _ -> {:error, "unexpected line in the request"}
    end
  end

  defp parse_vars(_lines, _request), do: {:error, "not a guiltty request"}

  defp add_var(request, "PWD", "/" <> _ = dir), do: {:ok, %{request | cwd: dir}}

  defp add_var(request, name, value) when name in @display_vars,
    do:
      {:ok,
       %{request | env: [{String.to_charlist(name), String.to_charlist(value)} | request.env]}}

  defp add_var(_request, _name, _value), do: :error

  defp open_window(%{env: env, cwd: cwd}, window_opts) do
    # The folder only if it's one: it may have been removed since, or not
    # be readable from here.
    cwd = if cwd && File.dir?(cwd), do: cwd

    if Process.whereis(Guiltty.Lifeline) do
      case Guiltty.Lifeline.open(
             window: Keyword.merge(window_opts, env: env ++ Keyword.get(window_opts, :env, [])),
             cwd: cwd
           ) do
        {:ok, _desk} -> :ok
        {:error, reason} -> {:error, "couldn't open a window: #{inspect(reason)}"}
      end
    else
      {:error, "shutting down"}
    end
  catch
    # Lifeline went away while we asked: it's shutting down.
    :exit, _ -> {:error, "shutting down"}
  end

  # The uid this BEAM runs as: the owner of its own /proc entry.
  defp my_uid, do: File.stat!("/proc/self").uid
end

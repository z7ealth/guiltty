defmodule Guiltty.Session do
  @moduledoc """
  Helpers for working with a session from iex.

      iex> [desk | _] = Guiltty.Desk.all()
      iex> id = Guiltty.Tabs.active(Guiltty.Desk.tabs(desk))
      iex> Guiltty.Session.write(id, "ls\\r")
      iex> Guiltty.Session.dump(id) |> IO.puts()
  """

  alias Guiltty.Session.{Pty, Screen}

  @doc "The registered name of one process in a session."
  def via(id, role), do: {:via, Registry, {Guiltty.Registry, {id, role}}}

  @doc """
  Starts a session process under its registered name.

  `start` gets the name and calls `GenServer.start_link/3` or
  `Supervisor.start_link/3`. If the name is still held by the previous
  incarnation, which happens when a supervisor is killed and restarted
  before its old children have finished exiting, this waits up to a second
  for that process to die and tries once more.
  """
  def start_named(id, role, start, value \\ nil) do
    # The value is stored with the name: a session's supervisor keeps its
    # desk's id there, so a desk can find its own sessions again.
    name = {:via, Registry, {Guiltty.Registry, {id, role}, value}}

    case start.(name) do
      {:error, {:already_started, old}} ->
        ref = Process.monitor(old)

        receive do
          {:DOWN, ^ref, :process, ^old, _reason} -> start.(name)
        after
          1_000 ->
            Process.demonitor(ref, [:flush])
            {:error, {:already_started, old}}
        end

      result ->
        result
    end
  end

  # Past this, a session's process is killed and restarted, and only that
  # tab loses anything: the VM running out of memory would take every tab.
  # 2 GB, in words: far more than any screen needs, even with a million rows
  # of scrollback, whose rows live in binaries.
  @max_heap_words div(2 * 1024 * 1024 * 1024, 8)

  @doc """
  Puts the calling process under the per-tab memory limit, or `words` if given
  (tests). From OTP 27 on the limit counts large binaries too, which is what
  a tab's rows and images are; on OTP 26 only the heap, so those have limits of
  their own (`:scrollback`, Guiltty.Graphics).
  """
  def limit_memory(words \\ nil) do
    limit = %{size: words || @max_heap_words, kill: true, error_logger: true}

    limit =
      if String.to_integer(System.otp_release()) >= 27,
        do: Map.put(limit, :include_shared_binaries, true),
        else: limit

    Process.flag(:max_heap_size, limit)
    :ok
  end

  @doc "Sends bytes to the shell. Use \"\\r\" for Enter."
  defdelegate write(id, bytes), to: Pty

  @doc "The session's screen as text."
  defdelegate dump(id), to: Screen

  @doc "The session's `{cols, rows}`."
  defdelegate size(id), to: Screen

  @doc """
  Resizes the session: the grid first, then the PTY. In that order, the
  redraw that SIGWINCH triggers lands on a grid that already has the new size.
  `cell_pixels` is one cell's `{width, height}` in pixels, or nil.
  """
  def resize(id, cols, rows, cell_pixels \\ nil) do
    # Nothing in the foreground but the shell: it's at its prompt, and the
    # SIGWINCH below makes it draw that again.
    :ok = Screen.resize(id, cols, rows, cell_pixels, at_prompt: Pty.busy(id) == nil)
    Pty.resize(id, cols, rows, cell_pixels)
  end
end

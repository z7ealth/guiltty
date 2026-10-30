defmodule Guiltty.Session.PtyNif do
  @moduledoc false
  # Thin bindings for c_src/pty_nif.c. Only Guiltty.Session.Pty calls these.

  @on_load :load_nif

  def load_nif do
    :guiltty
    |> :code.priv_dir()
    |> Path.join("pty_nif")
    |> String.to_charlist()
    |> :erlang.load_nif(0)
  end

  @doc """
  Opens a PTY and runs `path` on it, in directory `cwd` ("" for the BEAM's
  own). Returns `{:ok, pty, os_pid}`.
  """
  def open(_path, _argv, _envp, _cols, _rows, _cwd), do: :erlang.nif_error(:not_loaded)

  @doc "Non-blocking read: `{:ok, bytes} | :eagain | :eof | {:error, reason}`."
  def read(_pty), do: :erlang.nif_error(:not_loaded)

  @doc "Non-blocking write: `{:ok, bytes_written} | :eagain | {:error, reason}`."
  def write(_pty, _bytes), do: :erlang.nif_error(:not_loaded)

  @doc "Sends `{:select, pty, :undefined, :ready_input}` once readable."
  def select_read(_pty), do: :erlang.nif_error(:not_loaded)

  @doc "Sends `{:select, pty, :undefined, :ready_output}` once writable."
  def select_write(_pty), do: :erlang.nif_error(:not_loaded)

  @doc "Sets the terminal size (TIOCSWINSZ); the kernel sends SIGWINCH."
  def resize(_pty, _cols, _rows), do: :erlang.nif_error(:not_loaded)

  @doc "Sends SIGWINCH to the foreground job, so full-screen programs redraw."
  def winch(_pty), do: :erlang.nif_error(:not_loaded)

  @doc "The terminal's foreground process group: `{:ok, pgid}` (tcgetpgrp)."
  def foreground(_pty), do: :erlang.nif_error(:not_loaded)

  @doc "Closes the master, which hangs up the child's terminal."
  def close(_pty), do: :erlang.nif_error(:not_loaded)

  @doc "Polls the child: `:running | :gone | {:exited, code} | {:signaled, signal}`."
  def wait(_pty), do: :erlang.nif_error(:not_loaded)

  @doc "Sends a signal (as an integer) to the child."
  def kill(_pty, _signal), do: :erlang.nif_error(:not_loaded)
end

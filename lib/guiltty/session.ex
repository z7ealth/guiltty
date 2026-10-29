defmodule Guiltty.Session do
  @moduledoc """
  Helpers for working with a session from iex.

      iex> Guiltty.Session.write(:main, "ls\\r")
      iex> Guiltty.Session.dump(:main) |> IO.puts()
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
  def start_named(id, role, start) do
    name = via(id, role)

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

  @doc "Sends bytes to the shell. Use \"\\r\" for Enter."
  defdelegate write(id, bytes), to: Pty

  @doc "The session's screen as text."
  defdelegate dump(id), to: Screen
end

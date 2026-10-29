defmodule Guiltty.Session do
  @moduledoc """
  Helpers for working with a session from iex.

      iex> Guiltty.Session.write(:main, "ls\\r")
      iex> Guiltty.Session.dump(:main) |> IO.puts()
  """

  alias Guiltty.Session.{Pty, Screen}

  @doc "The registered name of one process in a session."
  def via(id, role), do: {:via, Registry, {Guiltty.Registry, {id, role}}}

  @doc "Sends bytes to the shell. Use \"\\r\" for Enter."
  defdelegate write(id, bytes), to: Pty

  @doc "The session's screen as text."
  defdelegate dump(id), to: Screen
end

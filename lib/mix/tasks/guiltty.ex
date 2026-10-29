defmodule Mix.Tasks.Guiltty do
  @shortdoc "Opens a guiltty window"
  @moduledoc """
  Starts guiltty and waits until it stops: when you close the window or
  type `exit` in the shell.

      mix guiltty
  """

  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    ref = Process.monitor(Guiltty.Supervisor)

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    end
  end
end

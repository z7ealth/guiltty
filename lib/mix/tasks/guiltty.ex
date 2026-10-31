defmodule Mix.Tasks.Guiltty do
  @shortdoc "Opens a guiltty window"
  @moduledoc """
  Starts guiltty and returns when guiltty stops: when the last window is
  closed (with no locked tabs left), or the last tab's shell exits.

      mix guiltty

  This is the development launcher.
  """

  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    wait()
  end

  # Wait until guiltty stops: when the last window (and its tabs) is gone,
  # Lifeline stops, and the application with it.
  defp wait do
    case Process.whereis(Guiltty.Lifeline) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, _pid, _reason} -> Process.sleep(100) && wait()
        end
    end
  end
end

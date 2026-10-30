defmodule Mix.Tasks.Guiltty do
  @shortdoc "Opens a guiltty window"
  @moduledoc """
  Starts guiltty and returns when you close the window, or when the last
  tab's shell exits.

      mix guiltty

  This is the development launcher: closing the window ends it (and the
  tabs with it). Detaching, closing the window and coming back to the same
  tabs, is what the release's `guiltty` command does.
  """

  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    wait()
  end

  # Wait for the window. A crashed renderer comes back as a new Window, so
  # when one goes down, look for its replacement before giving up.
  defp wait do
    case find_window(20) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, _pid, _reason} -> wait()
        end
    end
  end

  defp find_window(0), do: nil

  defp find_window(tries) do
    Process.whereis(Guiltty.Window) ||
      (Process.whereis(Guiltty.Supervisor) && Process.sleep(50) && find_window(tries - 1))
  end
end

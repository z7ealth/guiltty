defmodule Guiltty do
  @moduledoc """
  guiltty, a GPU terminal on the BEAM.

  The tabs (`Guiltty.Tabs`) live as long as guiltty runs; windows come and
  go. `open_window/1` shows them, starting a window or bringing the open one
  to the front.
  """

  @doc """
  Opens a window on the running tabs, or raises the open one.

  Options are passed to `Guiltty.Window`. `env64:` is the release
  launcher's way to pass the caller's display variables (base64 of
  `NAME=value` lines), so a window opens on the display it was asked from.
  """
  def open_window(opts \\ []) do
    opts = decode_env(opts)

    case Process.whereis(Guiltty.Window) do
      nil ->
        case DynamicSupervisor.start_child(Guiltty.Windows, {Guiltty.Window, opts}) do
          {:ok, _pid} -> :ok
          {:error, reason} -> {:error, reason}
        end

      pid ->
        send(pid, :raise)
        :ok
    end
  end

  # Only the variables a renderer needs to reach the display.
  @display_vars ~w(DISPLAY WAYLAND_DISPLAY XAUTHORITY XDG_RUNTIME_DIR)

  defp decode_env(opts) do
    case Keyword.pop(opts, :env64) do
      {nil, opts} ->
        opts

      {env64, opts} ->
        env =
          for line <- env64 |> Base.decode64!() |> String.split("\n", trim: true),
              [name, value] <- [String.split(line, "=", parts: 2)],
              name in @display_vars,
              do: {String.to_charlist(name), String.to_charlist(value)}

        Keyword.put(opts, :env, env)
    end
  end
end

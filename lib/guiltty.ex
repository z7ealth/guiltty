defmodule Guiltty do
  @moduledoc """
  guiltty, a GPU terminal on the BEAM.

  Every window is a desk (`Guiltty.Desk`): its own tabs and its own
  renderer, independent of the others. `open_window/1` opens a new one.
  """

  @doc """
  Opens a new window, with one new tab.

  Options are passed to `Guiltty.Window`. `env64:` is the release
  launcher's way to pass the caller's display variables (base64 of
  `NAME=value` lines), so a window opens on the display it was asked from.
  """
  def open_window(opts \\ []) do
    case Guiltty.Lifeline.open(window: decode_env(opts)) do
      {:ok, _desk} -> :ok
      {:error, reason} -> {:error, reason}
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

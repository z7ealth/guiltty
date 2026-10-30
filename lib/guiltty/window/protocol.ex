defmodule Guiltty.Window.Protocol do
  @moduledoc """
  The messages between `Guiltty.Window` and the renderer.

  The port's `{:packet, 4}` option adds and strips the 4-byte length; these
  functions only deal with what's inside. All integers are big-endian.
  Keep in sync with `c_src/renderer/core/protocol.h`.
  """

  alias Guiltty.Theme

  @version 3

  @hello 1
  @setup 2
  @rows 3
  @text 4
  @key 5
  @resize 6
  @title 7
  @paste 8
  @mouse 9

  @type event ::
          {:hello, version :: non_neg_integer(), backend :: binary()}
          | {:text, binary()}
          | {:key, keycode :: non_neg_integer(), mods :: non_neg_integer()}
          | {:resize, cols :: pos_integer(), rows :: pos_integer()}
          | {:paste, binary()}
          | {:mouse, :press | :release | :motion | :wheel, 0..3, non_neg_integer(),
             non_neg_integer(), non_neg_integer()}

  @doc "The protocol version this side speaks."
  def version, do: @version

  @doc "Initial grid size and the theme: 256 palette colors, then fg, bg and cursor."
  @spec setup(pos_integer(), pos_integer(), Theme.t()) :: iodata()
  def setup(cols, rows, theme) do
    colors = Theme.palette(theme) ++ [theme.fg, theme.bg, theme.cursor]
    [<<@setup, cols::16, rows::16>> | Enum.map(colors, fn {r, g, b} -> <<r, g, b>> end)]
  end

  @doc """
  A screen update. Rows are sent as the grid stores them: `cols` cells of
  10 bytes each. The renderer drops updates whose size doesn't match its
  own (they were sent before a resize reached the screen).
  """
  @spec rows(map()) :: iodata()
  def rows(%{size: {cols, rows}, rows: lines, cursor: {crow, ccol}, cursor_visible: visible}) do
    header = <<@rows, cols::16, rows::16, crow::16, ccol::16, bool(visible), length(lines)::16>>
    [header | Enum.map(lines, fn {index, row} -> [<<index::16>>, row] end)]
  end

  @doc "The window title (UTF-8)."
  @spec title(binary()) :: binary()
  def title(text), do: <<@title, text::binary>>

  @mouse_kinds %{0 => :press, 1 => :release, 2 => :motion, 3 => :wheel}

  @spec decode(binary()) :: {:ok, event()} | {:error, {:bad_message, binary()}}
  def decode(<<@hello, version::16, len, name::binary-size(len)>>),
    do: {:ok, {:hello, version, name}}

  def decode(<<@text, text::binary>>), do: {:ok, {:text, text}}
  def decode(<<@key, keycode::32, mods::16>>), do: {:ok, {:key, keycode, mods}}

  def decode(<<@resize, cols::16, rows::16>>) when cols > 0 and rows > 0,
    do: {:ok, {:resize, cols, rows}}

  def decode(<<@paste, text::binary>>), do: {:ok, {:paste, text}}

  def decode(<<@mouse, kind, button, col::16, row::16, mods::16>>)
      when is_map_key(@mouse_kinds, kind) and button <= 3,
      do: {:ok, {:mouse, @mouse_kinds[kind], button, col, row, mods}}

  def decode(other), do: {:error, {:bad_message, other}}

  defp bool(true), do: 1
  defp bool(false), do: 0
end

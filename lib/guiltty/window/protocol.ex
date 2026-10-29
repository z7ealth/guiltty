defmodule Guiltty.Window.Protocol do
  @moduledoc """
  The messages between `Guiltty.Window` and the renderer.

  The port's `{:packet, 4}` option adds and strips the 4-byte length; these
  functions only deal with what's inside. All integers are big-endian.
  Keep in sync with `c_src/renderer/core/protocol.h`.
  """

  @version 1

  @hello 1
  @setup 2
  @rows 3
  @text 4
  @key 5

  @type event ::
          {:hello, version :: non_neg_integer(), backend :: binary()}
          | {:text, binary()}
          | {:key, keycode :: non_neg_integer(), mods :: non_neg_integer()}

  @doc "The protocol version this side speaks."
  def version, do: @version

  @spec setup(pos_integer(), pos_integer()) :: binary()
  def setup(cols, rows), do: <<@setup, cols::16, rows::16>>

  @doc "Changed rows plus the cursor, as `{row, col}`."
  @spec rows([{non_neg_integer(), binary()}], {non_neg_integer(), non_neg_integer()}) :: iodata()
  def rows(rows, {cursor_row, cursor_col}) do
    [
      <<@rows, cursor_row::16, cursor_col::16, length(rows)::16>>
      | Enum.map(rows, fn {index, bytes} -> [<<index::16, byte_size(bytes)::16>>, bytes] end)
    ]
  end

  @spec decode(binary()) :: {:ok, event()} | {:error, {:bad_message, binary()}}
  def decode(<<@hello, version::16, len, name::binary-size(len)>>),
    do: {:ok, {:hello, version, name}}

  def decode(<<@text, text::binary>>), do: {:ok, {:text, text}}
  def decode(<<@key, keycode::32, mods::16>>), do: {:ok, {:key, keycode, mods}}
  def decode(other), do: {:error, {:bad_message, other}}
end

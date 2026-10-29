defmodule Guiltty.Window.ProtocolTest do
  use ExUnit.Case, async: true

  alias Guiltty.{Grid, Theme}
  alias Guiltty.Window.Protocol

  test "setup carries the size and 259 colors" do
    bin = IO.iodata_to_binary(Protocol.setup(80, 24, Theme.default()))
    assert <<2, 80::16, 24::16, colors::binary>> = bin
    assert byte_size(colors) == 259 * 3
    # palette 196 is pure red in the cube
    assert binary_part(colors, 196 * 3, 3) == <<255, 0, 0>>
    # the last three are fg, bg and cursor
    assert binary_part(colors, 257 * 3, 3) == <<0x1D, 0x1F, 0x21>>
  end

  test "rows carry the size, the cursor and raw grid rows" do
    row = Grid.new(2, 1).lines |> elem(0)
    update = %{size: {2, 1}, rows: [{0, row}], cursor: {0, 1}, cursor_visible: false}
    bin = IO.iodata_to_binary(Protocol.rows(update))
    assert <<3, 2::16, 1::16, 0::16, 1::16, 0, 1::16, 0::16, cells::binary>> = bin
    assert cells == row
    assert byte_size(cells) == 2 * Grid.cell_size()
  end

  test "decodes renderer events" do
    assert Protocol.decode(<<1, 0, 2, 2, "gl">>) == {:ok, {:hello, 2, "gl"}}
    assert Protocol.decode(<<4, "hé">>) == {:ok, {:text, "hé"}}
    assert Protocol.decode(<<5, 0, 0, 0, ?c, 0, 0x40>>) == {:ok, {:key, ?c, 0x40}}
    assert Protocol.decode(<<6, 100::16, 30::16>>) == {:ok, {:resize, 100, 30}}
    assert {:error, {:bad_message, _}} = Protocol.decode(<<6, 0::16, 30::16>>)
    assert {:error, {:bad_message, _}} = Protocol.decode(<<99>>)
  end

  test "the palette is xterm's layout" do
    palette = Theme.palette(Theme.default())
    assert length(palette) == 256
    assert Enum.at(palette, 16) == {0, 0, 0}
    assert Enum.at(palette, 231) == {255, 255, 255}
    assert Enum.at(palette, 232) == {8, 8, 8}
    assert Enum.at(palette, 255) == {238, 238, 238}
  end
end

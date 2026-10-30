defmodule Guiltty.Window.ProtocolTest do
  use ExUnit.Case, async: true

  alias Guiltty.{Grid, Theme}
  alias Guiltty.Window.Protocol

  @options %{padding: 6, opacity: 0.9, bold_is_bright: true}

  test "setup carries the size, 259 colors, the options and the font" do
    bin =
      IO.iodata_to_binary(
        Protocol.setup(80, 24, Theme.default(), %{family: "monospace", size: 18}, @options)
      )

    assert <<2, 80::16, 24::16, colors::binary-size(777), 6::16, 90, 1, 18::16, "monospace">> =
             bin

    # palette 196 is pure red in the cube
    assert binary_part(colors, 196 * 3, 3) == <<255, 0, 0>>
    # the last three are fg, bg and cursor
    assert binary_part(colors, 257 * 3, 3) == <<0x1D, 0x1F, 0x21>>
  end

  test "rows carry the size, the cursor, new clusters and raw grid rows" do
    row = Grid.new(2, 1).lines |> elem(0)

    update = %{
      size: {2, 1},
      rows: [{0, row}],
      clusters: [{0x110000, "🇯🇵"}],
      cursor: {0, 1},
      cursor_visible: false,
      cursor_style: {:bar, true}
    }

    bin = IO.iodata_to_binary(Protocol.rows(update))

    # cursor style 6: bar (2) + blinking (4)
    assert <<3, 2::16, 1::16, 0::16, 1::16, 0, 6, 1::16, 0x110000::32, 8, "🇯🇵", 1::16, 0::16,
             cells::binary>> = bin

    assert cells == row
    assert byte_size(cells) == 2 * Grid.cell_size()
  end

  test "decodes renderer events" do
    assert Protocol.decode(<<1, 0, 8, 2, "gl">>) == {:ok, {:hello, 8, "gl"}}
    assert Protocol.decode(<<15, 1234::32>>) == {:ok, {:frame, 1234}}
    assert Protocol.decode(<<16, 2>>) == {:ok, {:tab_click, 2}}
    assert Protocol.decode(<<4, "hé">>) == {:ok, {:text, "hé"}}
    assert Protocol.decode(<<5, 0, 0, 0, ?c, 0, 0x40>>) == {:ok, {:key, ?c, 0x40}}
    assert Protocol.decode(<<6, 100::16, 30::16>>) == {:ok, {:resize, 100, 30}}
    assert {:error, {:bad_message, _}} = Protocol.decode(<<6, 0::16, 30::16>>)
    assert {:error, {:bad_message, _}} = Protocol.decode(<<99>>)
    assert Protocol.decode(<<8, "a\nb">>) == {:ok, {:paste, "a\nb"}}

    assert Protocol.decode(<<9, 0, 2, 4::16, 7::16, 0x40::16, 2>>) ==
             {:ok, {:mouse, :press, 2, 4, 7, 0x40, 2}}

    assert Protocol.decode(<<9, 3, 1, 0::16, 0::16, 0::16, 1>>) ==
             {:ok, {:mouse, :wheel, 1, 0, 0, 0, 1}}

    assert {:error, {:bad_message, _}} = Protocol.decode(<<9, 7, 0, 0::16, 0::16, 0::16, 1>>)
  end

  test "encodes live options and URLs to open" do
    assert IO.iodata_to_binary(Protocol.options(%{@options | bold_is_bright: false})) ==
             <<20, 6::16, 90, 0>>

    assert IO.iodata_to_binary(Protocol.options(Map.put(@options, :tab_bar, :bottom))) ==
             <<20, 6::16, 90, 0b11>>

    assert IO.iodata_to_binary(Protocol.options(Map.put(@options, :ligatures, true))) ==
             <<20, 6::16, 90, 0b101>>

    assert Protocol.open_url("file:///tmp/x.exs") == <<21, "file:///tmp/x.exs">>
  end

  test "encodes the status, normal or a warning" do
    assert Protocol.status("find: x") == <<17, 0, "find: x">>
    assert Protocol.status(:warning, "⚠ bad") == <<17, 1, "⚠ bad">>
  end

  test "encodes the title" do
    assert Protocol.title("vim") == <<7, "vim">>
  end

  test "encodes tabs, cutting long titles on a character boundary" do
    assert IO.iodata_to_binary(Protocol.tabs(["a", "bc"], 1)) == <<12, 1, 2, 1, "a", 2, "bc">>
    long = String.duplicate("é", 200)
    <<12, 0, 1, len, title::binary>> = IO.iodata_to_binary(Protocol.tabs([long], 0))
    assert len == byte_size(title) and len <= 255 and String.valid?(title)
  end

  test "encodes the theme, font, halo and raise" do
    assert <<10, colors::binary>> = IO.iodata_to_binary(Protocol.theme(Theme.default()))
    assert byte_size(colors) == 777

    assert IO.iodata_to_binary(Protocol.font(%{family: "Mono", size: 20})) ==
             <<11, 20::16, "Mono">>

    assert Protocol.halo({1, 2, 3}, 400) == <<13, 1, 2, 3, 400::16>>
    assert Protocol.raise_window() == <<14>>
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

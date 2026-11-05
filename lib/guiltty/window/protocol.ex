defmodule Guiltty.Window.Protocol do
  @moduledoc """
  The messages between `Guiltty.Window` and the renderer.

  The port's `{:packet, 4}` option adds and strips the 4-byte length; these
  functions only deal with what's inside. All integers are big-endian.
  Keep in sync with `c_src/renderer/core/protocol.h`.
  """

  import Bitwise

  alias Guiltty.Theme

  @version 12

  @hello 1
  @setup 2
  @rows 3
  @text 4
  @key 5
  @resize 6
  @title 7
  @paste 8
  @mouse 9
  @theme 10
  @font 11
  @tabs 12
  @halo 13
  @raise 14
  @frame 15
  @tab_click 16
  @status 17
  @clipboard 18
  @paste_primary 19
  @options 20
  @open_url 21
  @tab_style 22
  @image 23
  @image_drop 24
  @placements 25

  @image_formats %{rgb: 0, rgba: 1, png: 2}

  @max_tab_title 255
  @max_grid 4096

  @type event ::
          {:hello, version :: non_neg_integer(), backend :: binary()}
          | {:text, binary()}
          | {:key, keycode :: non_neg_integer(), mods :: non_neg_integer()}
          | {:resize, cols :: pos_integer(), rows :: pos_integer(),
             cell_pixels :: {pos_integer(), pos_integer()} | nil}
          | {:paste, binary()}
          | {:mouse, :press | :release | :motion | :wheel, 0..3, non_neg_integer(),
             non_neg_integer(), non_neg_integer(), clicks :: 1..255}
          | {:frame, draw_us :: non_neg_integer()}
          | {:tab_click, index :: non_neg_integer()}

  @doc "The protocol version this side speaks."
  def version, do: @version

  @doc """
  Initial grid size, the theme's 259 colors, the window options (see
  `options/1`), then the font (u16 size, family).
  """
  @spec setup(pos_integer(), pos_integer(), Theme.t(), map(), map()) :: iodata()
  def setup(cols, rows, theme, font, options) do
    [
      <<@setup, cols::16, rows::16>>,
      colors(theme),
      option_bytes(options),
      <<font.size::16>>,
      font.family
    ]
  end

  @doc """
  Window options, live: u16 padding (pixels at scale 1), u8 opacity
  (percent), u8 flags (bit 0: bold is bright, bit 1: tab bar at the
  bottom, bit 2: ligatures).
  """
  def options(options), do: [<<@options>>, option_bytes(options)]

  defp option_bytes(%{padding: padding, opacity: opacity, bold_is_bright: bright} = o) do
    bottom = Map.get(o, :tab_bar, :top) == :bottom
    ligatures = Map.get(o, :ligatures, false)
    <<padding::16, round(opacity * 100), bool(bright) + 2 * bool(bottom) + 4 * bool(ligatures)>>
  end

  @doc "Ask the renderer to open a URL (a file:// one opens the file in its app)."
  def open_url(url), do: <<@open_url, url::binary>>

  @doc """
  An image for the renderer to decode and keep, by `uid`: u64 uid, u8
  format (0 RGB, 1 RGBA, 2 PNG), u32 width, u32 height, then the data.
  """
  def image(uid, image) do
    [
      <<@image, uid::64, Map.fetch!(@image_formats, image.format), image.width::32,
        image.height::32>>,
      image.data
    ]
  end

  @doc "The renderer can forget an image: u64 uid."
  def image_drop(uid), do: <<@image_drop, uid::64>>

  @doc """
  Where images show, for the grid of `{cols, rows}` (like ROWS, a
  renderer with another size ignores it). u16 cols, u16 rows, u16
  count, then per placement (see `Guiltty.Graphics.view/4`): u64 uid,
  i32 row, u16 col, u16 x and y offset in the cell, u32 source x, y,
  width, height, u16 cells wide and high (0: natural size), i32 z.
  Drawn in this order.
  """
  def placements({cols, rows}, placements) do
    placements = Enum.take(placements, 1024)

    [
      <<@placements, cols::16, rows::16, length(placements)::16>>,
      for pl <- placements do
        {ox, oy} = pl.offset
        {sx, sy, sw, sh} = pl.source
        {c, r} = pl.cells

        <<pl.uid::64, pl.row::signed-32, pl.col::16, ox::16, oy::16, sx::32, sy::32, sw::32,
          sh::32, c::16, r::16, pl.z::signed-32>>
      end
    ]
  end

  @tab_styles [:flat, :powerline, :rounded, :minimal, :separators]

  @doc """
  How the tab bar looks: u8 style (flat, powerline, rounded, minimal,
  separators), u8 which colors are given (bit i: the theme's i-th tab
  color, see `Guiltty.Theme.tab_colors/0`), then those five colors, 3
  bytes each (0, 0, 0 for one not given: the renderer derives it).
  """
  def tab_style(style, theme) do
    colors = Enum.map(Theme.tab_colors(), &Map.get(theme, &1))

    set =
      colors
      |> Enum.with_index()
      |> Enum.reduce(0, fn {color, i}, acc -> if color, do: acc + (1 <<< i), else: acc end)

    [
      <<@tab_style, Enum.find_index(@tab_styles, &(&1 == style)), set>>,
      for(
        color <- colors,
        do: if(color, do: <<elem(color, 0), elem(color, 1), elem(color, 2)>>, else: <<0, 0, 0>>)
      )
    ]
  end

  @doc "A new theme: the same 259 colors as the setup."
  def theme(theme), do: [<<@theme>>, colors(theme)]

  @doc "A new font: u16 pixel size, then the family name for fontconfig."
  def font(font), do: [<<@font, font.size::16>>, font.family]

  defp colors(theme) do
    for {r, g, b} <- Theme.palette(theme) ++ [theme.fg, theme.bg, theme.cursor], do: <<r, g, b>>
  end

  @doc """
  A screen update. After the cursor (position, visible, and a style byte:
  bits 0-1 block, underline or bar, bit 2 blinking) come the clusters the
  renderer hasn't seen (u32 id, u8 length, UTF-8), then the rows, sent as the grid stores them: `cols`
  cells of 14 bytes each. The renderer drops updates whose size doesn't
  match its own (they were sent before a resize reached the screen).
  """
  @spec rows(map()) :: iodata()
  def rows(%{size: {cols, rows}, rows: lines, cursor: {crow, ccol}, cursor_visible: visible} = u) do
    clusters = Map.get(u, :clusters, [])
    style = cursor_byte(Map.get(u, :cursor_style) || {:block, false})

    [
      <<@rows, cols::16, rows::16, crow::16, ccol::16, bool(visible), style,
        length(clusters)::16>>,
      Enum.map(clusters, fn {id, text} -> [<<id::32, byte_size(text)>>, text] end),
      <<length(lines)::16>>
      | Enum.map(lines, fn {index, row} -> [<<index::16>>, row] end)
    ]
  end

  @doc """
  A line of status at the right of the tab bar (search, scrollback, a
  config error): u8 style (0 normal, 1 warning), then the text. Empty
  hides it.
  """
  def status(style \\ :normal, text),
    do: <<@status, if(style == :warning, do: 1, else: 0), truncate(text, 255)::binary>>

  @doc "Put text on the clipboard (`:clipboard`) or the primary selection (`:primary`)."
  def clipboard(target, text),
    do: <<@clipboard, if(target == :primary, do: 1, else: 0), text::binary>>

  @doc "Ask for the primary selection: the renderer answers with a paste."
  def paste_primary, do: <<@paste_primary>>

  @doc "The window title (UTF-8)."
  @spec title(binary()) :: binary()
  def title(text), do: <<@title, text::binary>>

  @doc "The tab bar: u8 active index, u8 count, then each title as u8 length + bytes."
  @spec tabs([binary()], non_neg_integer()) :: iodata()
  def tabs(titles, active) do
    titles = Enum.take(titles, 255)

    [
      <<@tabs, active, length(titles)>>
      | Enum.map(titles, fn t ->
          t = truncate(t, @max_tab_title)
          [<<byte_size(t)>>, t]
        end)
    ]
  end

  @doc "Flash the window's border in a color for some milliseconds."
  def halo({r, g, b}, ms), do: <<@halo, r, g, b, min(ms, 65_535)::16>>

  @doc "Bring the window to the front."
  def raise_window, do: <<@raise>>

  @mouse_kinds %{0 => :press, 1 => :release, 2 => :motion, 3 => :wheel}

  @spec decode(binary()) :: {:ok, event()} | {:error, {:bad_message, binary()}}
  def decode(<<@hello, version::16, len, name::binary-size(len)>>),
    do: {:ok, {:hello, version, name}}

  def decode(<<@text, text::binary>>), do: {:ok, {:text, text}}
  def decode(<<@key, keycode::32, mods::16>>), do: {:ok, {:key, keycode, mods}}

  # The renderer's own limit (max_grid in main.c): a grid bigger than that
  # is a broken message, not a window.
  # The cell size in pixels comes after; 0 means the renderer doesn't know.
  def decode(<<@resize, cols::16, rows::16, cell_w::16, cell_h::16>>)
      when cols in 1..@max_grid and rows in 1..@max_grid do
    cell_pixels = if cell_w > 0 and cell_h > 0, do: {cell_w, cell_h}
    {:ok, {:resize, cols, rows, cell_pixels}}
  end

  def decode(<<@paste, text::binary>>), do: {:ok, {:paste, text}}

  def decode(<<@mouse, kind, button, col::16, row::16, mods::16, clicks>>)
      when is_map_key(@mouse_kinds, kind) and button <= 3,
      do: {:ok, {:mouse, @mouse_kinds[kind], button, col, row, mods, max(clicks, 1)}}

  def decode(<<@frame, us::32>>), do: {:ok, {:frame, us}}
  def decode(<<@tab_click, index>>), do: {:ok, {:tab_click, index}}
  def decode(other), do: {:error, {:bad_message, other}}

  # Bits 0-1 the shape (0 block, 1 underline, 2 bar), bit 2 blinking.
  defp cursor_byte({shape, blink}) do
    Map.fetch!(%{block: 0, underline: 1, bar: 2}, shape) + if(blink, do: 4, else: 0)
  end

  defp bool(true), do: 1
  defp bool(false), do: 0

  # Cut to at most `max` bytes without splitting a UTF-8 character.
  defp truncate(text, max) when byte_size(text) <= max, do: text

  defp truncate(text, max) do
    text |> binary_part(0, max) |> String.chunk(:valid) |> List.first("")
  end
end

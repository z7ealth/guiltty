defmodule Guiltty.Window.Protocol do
  @moduledoc """
  The messages between `Guiltty.Window` and the renderer.

  The port's `{:packet, 4}` option adds and strips the 4-byte length; these
  functions only deal with what's inside. All integers are big-endian.
  Keep in sync with `c_src/renderer/core/protocol.h`.
  """

  alias Guiltty.Theme

  @version 8

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

  @max_tab_title 255

  @type event ::
          {:hello, version :: non_neg_integer(), backend :: binary()}
          | {:text, binary()}
          | {:key, keycode :: non_neg_integer(), mods :: non_neg_integer()}
          | {:resize, cols :: pos_integer(), rows :: pos_integer()}
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
  bottom).
  """
  def options(options), do: [<<@options>>, option_bytes(options)]

  defp option_bytes(%{padding: padding, opacity: opacity, bold_is_bright: bright} = o) do
    bottom = Map.get(o, :tab_bar, :top) == :bottom
    <<padding::16, round(opacity * 100), bool(bright) + 2 * bool(bottom)>>
  end

  @doc "Ask the renderer to open a URL (a file:// one opens the file in its app)."
  def open_url(url), do: <<@open_url, url::binary>>

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

  def decode(<<@resize, cols::16, rows::16>>) when cols > 0 and rows > 0,
    do: {:ok, {:resize, cols, rows}}

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

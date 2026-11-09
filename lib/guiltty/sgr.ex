defmodule Guiltty.SGR do
  @moduledoc """
  SGR, Select Graphic Rendition (`CSI ... m`): sets the pen that new text
  is written with.

  | Parameter       | Effect                                  |
  |-----------------|-----------------------------------------|
  | none, `0`       | reset everything                        |
  | `1` `2` `3` `4` | bold, dim, italic, underline            |
  | `5` `7` `8` `9` | blink, inverse, hidden, strikethrough   |
  | `21`            | double underline (drawn as underline)   |
  | `22`..`29`      | turn those off (22 = bold and dim)      |
  | `30`..`37`      | foreground palette 0-7                  |
  | `90`..`97`      | foreground palette 8-15 (bright)        |
  | `40`..`47`, `100`..`107` | the same for the background    |
  | `38;5;n`, `48;5;n` | palette color n (0-255)              |
  | `38;2;r;g;b`, `48;2;r;g;b` | 24-bit color                 |
  | `39`, `49`      | default foreground, background          |
  | `53`, `55`      | overline, and off                       |
  | `58;...`, `59`  | underline color: read and not used      |

  The extended colors also come in the colon form, `38:5:n` and
  `38:2::r:g:b` (with an optional color-space id between the colons).
  """

  import Bitwise

  alias Guiltty.Grid

  @spec apply(Grid.t(), [Guiltty.Parser.param()]) :: Grid.t()
  def apply(grid, []), do: reset(grid)

  def apply(grid, params) do
    {attrs, fg, bg} = sgr(params, {grid.attrs, grid.fg, grid.bg})
    Grid.set_pen(grid, attrs, fg, bg)
  end

  defp reset(grid), do: Grid.set_pen(grid, 0, 0, 0)

  defp sgr([], pen), do: pen

  # Underline color. There's no room for it in a cell, so it's skipped whole:
  # taken one by one, 58;5;1 would turn on blink and bold.
  defp sgr([58, 5, _n | rest], pen), do: sgr(rest, pen)
  defp sgr([58, 2, _r, _g, _b | rest], pen), do: sgr(rest, pen)
  defp sgr([[58 | _] | rest], pen), do: sgr(rest, pen)

  # 38;5;n  38;2;r;g;b  (and 48 for the background)
  defp sgr([which, 5, n | rest], pen) when which in [38, 48],
    do: sgr(rest, color(pen, which, Grid.indexed(byte(n))))

  defp sgr([which, 2, r, g, b | rest], pen) when which in [38, 48],
    do: sgr(rest, color(pen, which, Grid.rgb(byte(r), byte(g), byte(b))))

  # 38:5:n  38:2::r:g:b  38:2:r:g:b
  defp sgr([[which, 5, n] | rest], pen) when which in [38, 48],
    do: sgr(rest, color(pen, which, Grid.indexed(byte(n))))

  defp sgr([[which, 2, _space, r, g, b] | rest], pen) when which in [38, 48],
    do: sgr(rest, color(pen, which, Grid.rgb(byte(r), byte(g), byte(b))))

  defp sgr([[which, 2, r, g, b] | rest], pen) when which in [38, 48],
    do: sgr(rest, color(pen, which, Grid.rgb(byte(r), byte(g), byte(b))))

  # 4:0 turns underline off; 4:1 .. 4:5 are underline styles, drawn as one.
  defp sgr([[4, 0] | rest], pen), do: sgr(rest, off(pen, :underline))
  defp sgr([[4, _style] | rest], pen), do: sgr(rest, on(pen, :underline))

  # Any other colon group: use its first value.
  defp sgr([[first | _] | rest], pen), do: sgr([first | rest], pen)

  defp sgr([n | rest], pen), do: sgr(rest, simple(n || 0, pen))

  defp simple(0, _pen), do: {0, 0, 0}
  defp simple(1, pen), do: on(pen, :bold)
  defp simple(2, pen), do: on(pen, :dim)
  defp simple(3, pen), do: on(pen, :italic)
  defp simple(4, pen), do: on(pen, :underline)
  defp simple(5, pen), do: on(pen, :blink)
  defp simple(6, pen), do: on(pen, :blink)
  defp simple(7, pen), do: on(pen, :inverse)
  defp simple(8, pen), do: on(pen, :hidden)
  defp simple(9, pen), do: on(pen, :strike)
  defp simple(21, pen), do: on(pen, :underline)
  defp simple(22, pen), do: pen |> off(:bold) |> off(:dim)
  defp simple(23, pen), do: off(pen, :italic)
  defp simple(24, pen), do: off(pen, :underline)
  defp simple(25, pen), do: off(pen, :blink)
  defp simple(27, pen), do: off(pen, :inverse)
  defp simple(28, pen), do: off(pen, :hidden)
  defp simple(29, pen), do: off(pen, :strike)
  defp simple(n, pen) when n in 30..37, do: color(pen, 38, Grid.indexed(n - 30))
  defp simple(39, pen), do: color(pen, 38, 0)
  defp simple(n, pen) when n in 40..47, do: color(pen, 48, Grid.indexed(n - 40))
  defp simple(49, pen), do: color(pen, 48, 0)
  defp simple(53, pen), do: on(pen, :overline)
  defp simple(55, pen), do: off(pen, :overline)
  defp simple(n, pen) when n in 90..97, do: color(pen, 38, Grid.indexed(n - 90 + 8))
  defp simple(n, pen) when n in 100..107, do: color(pen, 48, Grid.indexed(n - 100 + 8))
  defp simple(_unknown, pen), do: pen

  defp on({attrs, fg, bg}, name), do: {attrs ||| Grid.attr(name), fg, bg}
  defp off({attrs, fg, bg}, name), do: {attrs &&& bnot(Grid.attr(name)), fg, bg}

  defp color({attrs, _fg, bg}, 38, c), do: {attrs, c, bg}
  defp color({attrs, fg, _bg}, 48, c), do: {attrs, fg, c}

  @doc """
  The pen as SGR parameters, for DECRQSS: what a program could send to get
  this pen back, starting from a reset.
  """
  def report(grid) do
    attrs =
      for {name, n} <- [
            bold: 1,
            dim: 2,
            italic: 3,
            underline: 4,
            blink: 5,
            inverse: 7,
            hidden: 8,
            strike: 9,
            overline: 53
          ],
          (grid.attrs &&& Grid.attr(name)) != 0,
          do: n

    [0 | attrs]
    |> Kernel.++(color_params(grid.fg, 30, 90, 38))
    |> Kernel.++(color_params(grid.bg, 40, 100, 48))
    |> Enum.join(";")
  end

  defp color_params(0, _base, _bright, _ext), do: []

  defp color_params(color, base, bright, ext) do
    case {color >>> 24, color &&& 0xFFFFFF} do
      {1, n} when n < 8 -> [base + n]
      {1, n} when n < 16 -> [bright + n - 8]
      {1, n} -> [ext, 5, n]
      {2, rgb} -> [ext, 2, rgb >>> 16, rgb >>> 8 &&& 0xFF, rgb &&& 0xFF]
    end
  end

  defp byte(nil), do: 0
  defp byte(n), do: min(n, 255)
end

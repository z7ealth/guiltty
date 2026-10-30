defmodule Guiltty.Unicode do
  @moduledoc """
  How many columns text takes.

  Programs ask glibc's `wcwidth(3)` how wide each character is, and line
  up their output by the answer. guiltty must agree, or everything after a
  disagreement shifts. So the table in `Guiltty.Unicode.WidthTable` is
  generated from glibc itself (`make width-table`).

  A *grapheme cluster* is what a reader sees as one character: `e` plus a
  combining accent, a flag (two regional indicators), an emoji with a skin
  tone. guiltty puts one cluster in one cell (two if it's wide). Its width
  is the sum of its characters' widths, as `wcswidth(3)` counts it, capped
  at 2:

      iex> Guiltty.Unicode.width("a")
      1
      iex> Guiltty.Unicode.width("中")
      2
      iex> Guiltty.Unicode.width("e\\u0301")
      1
      iex> Guiltty.Unicode.width("🇯🇵")
      2

  The cap is where guiltty and programs can still disagree: a ZWJ sequence
  like 👨‍👩‍👧 is three wide emoji joined into one picture. `wcswidth` says 6,
  guiltty draws it in 2.
  """

  import Bitwise

  alias Guiltty.Unicode.WidthTable

  @zero WidthTable.zero()
  @wide WidthTable.wide()

  @doc "The width of one codepoint: 0, 1 or 2."
  @spec char_width(non_neg_integer()) :: 0 | 1 | 2
  def char_width(cp) when cp < 0x300, do: 1

  def char_width(cp) do
    cond do
      in_ranges?(@wide, cp) -> 2
      in_ranges?(@zero, cp) -> 0
      true -> 1
    end
  end

  @doc "The width of a grapheme cluster: 1 or 2."
  @spec width(binary()) :: 1 | 2
  def width(<<c>>) when c < 0x80, do: 1

  def width(cluster) do
    sum = for <<cp::utf8 <- cluster>>, reduce: 0, do: (acc -> acc + char_width(cp))
    sum |> max(1) |> min(2)
  end

  # Binary search over sorted, non-overlapping {lo, hi} ranges.
  defp in_ranges?(ranges, cp), do: search(ranges, cp, 0, tuple_size(ranges) - 1)

  defp search(_ranges, _cp, lo, hi) when lo > hi, do: false

  defp search(ranges, cp, lo, hi) do
    mid = (lo + hi) >>> 1

    case elem(ranges, mid) do
      {a, _b} when cp < a -> search(ranges, cp, lo, mid - 1)
      {_a, b} when cp > b -> search(ranges, cp, mid + 1, hi)
      _ -> true
    end
  end
end

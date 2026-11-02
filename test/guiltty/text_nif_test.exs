defmodule Guiltty.TextNifTest do
  # The text NIF (c_src/text_nif.c) turns runs of text into cells and hands
  # back what might join as text. Together, the two must give exactly the
  # clusters and widths Elixir gives on its own: String.graphemes/1 over
  # the whole text, and Guiltty.Unicode.width/1 for each cluster.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias Guiltty.{Grid, TextNif, Unicode}

  defp elixir(text), do: for(g <- String.graphemes(text), do: {g, Unicode.width(g)})

  # The NIF's answer in the same shape: cells read back into
  # {character, width}, text segmented by Elixir.
  defp nif(text), do: for(seg <- TextNif.segments(text, 0, 0, 0), unit <- units(seg), do: unit)

  defp units({cells, cols}) do
    assert byte_size(cells) == cols * Grid.cell_size()

    for <<glyph::32, attrs::16, _fg::32, _bg::32 <- cells>>,
        (attrs &&& Grid.attr(:spacer)) == 0 do
      {<<glyph::utf8>>, if((attrs &&& Grid.attr(:wide)) != 0, do: 2, else: 1)}
    end
  end

  defp units(text) when is_binary(text), do: elixir(text)

  test "text where nothing can join is all cells" do
    text = "héllo wörld ✓ → 漢字 🚀"
    assert [{_cells, 23}] = TextNif.segments(text, 0, 0, 0)
    assert nif(text) == elixir(text)
  end

  test "what might join comes back as text, with the simple neighbour before it" do
    # 🚀 is simple, but a skin tone can follow it; d follows the tone.
    assert [{_, 3}, "🚀🏽d", {_, 2}] = TextNif.segments("abc🚀🏽def", 0, 0, 0)
    assert ["e\u{0301}"] = TextNif.segments("e\u{0301}", 0, 0, 0)
    assert [{_, 1}, "a🇯🇵b", {_, 1}] = TextNif.segments("xa🇯🇵by", 0, 0, 0)
  end

  test "cells are in the grid's layout, in the pen" do
    {attrs, fg, bg} = {Grid.attr(:bold), Grid.indexed(1), Grid.rgb(1, 2, 3)}

    assert [{cells, 3}] = TextNif.segments("é中", attrs, fg, bg)

    assert cells ==
             <<?é::32, attrs::16, fg::32, bg::32>> <>
               <<?中::32, attrs ||| Grid.attr(:wide)::16, fg::32, bg::32>> <>
               <<0::32, attrs ||| Grid.attr(:spacer)::16, fg::32, bg::32>>
  end

  test "empty text has no segments" do
    assert TextNif.segments("", 0, 0, 0) == []
  end

  test "invalid UTF-8 and a bad pen are argument errors" do
    for bad <- [<<0xFF>>, <<0xC3>>, <<0xC0, 0x80>>, <<0xED, 0xA0, 0x80>>, <<0xF4, 0x90, 0, 0>>] do
      assert_raise ArgumentError, fn -> TextNif.segments("ok" <> bad, 0, 0, 0) end
    end

    assert_raise ArgumentError, fn -> TextNif.segments("ok", 0x10000, 0, 0) end
    assert_raise ArgumentError, fn -> TextNif.segments("ok", 0, -1, 0) end
  end

  # The NIF runs inside the BEAM, where a crash takes every tab with it.
  # Whatever it's given, it answers or raises ArgumentError. The Parser
  # only ever sends valid UTF-8, but the NIF doesn't rely on that.
  property "random bytes give Elixir's clusters, or an ArgumentError" do
    check all(bytes <- StreamData.binary(max_length: 64)) do
      case safe(bytes) do
        {:error, :badarg} -> refute String.valid?(bytes)
        _segments -> assert nif(bytes) == elixir(bytes)
      end
    end
  end

  property "junk arguments raise ArgumentError" do
    check all(args <- StreamData.list_of(StreamData.term(), length: 4)) do
      assert match?({:error, :badarg}, safe_apply(args)) or valid_args?(args)
    end
  end

  defp safe(bytes), do: safe_apply([bytes, 0, 0, 0])

  defp safe_apply(args) do
    apply(TextNif, :segments, args)
  rescue
    ArgumentError -> {:error, :badarg}
  end

  defp valid_args?([text, attrs, fg, bg]) do
    is_binary(text) and String.valid?(text) and attrs in 0..0xFFFF and
      Enum.all?([fg, bg], &(is_integer(&1) and &1 in 0..0xFFFFFFFF))
  end

  # The three helpers, each against the Elixir it replaced.
  property "text_run, ascii? and ascii_cells agree with their Elixir versions" do
    check all(bytes <- StreamData.binary(max_length: 64)) do
      run = Enum.find_index(:binary.bin_to_list(bytes), &(&1 < 0x20 or &1 == 0x7F))
      assert TextNif.text_run(bytes) == (run || byte_size(bytes))

      assert TextNif.ascii?(bytes) == Enum.all?(:binary.bin_to_list(bytes), &(&1 < 0x80))

      {attrs, fg, bg} = {Grid.attr(:underline), Grid.indexed(5), Grid.rgb(1, 2, 3)}

      assert TextNif.ascii_cells(bytes, attrs, fg, bg) ==
               for(<<c <- bytes>>, into: <<>>, do: <<c::32, attrs::16, fg::32, bg::32>>)
    end
  end

  test "the helpers refuse what isn't a binary or a pen" do
    assert_raise ArgumentError, fn -> TextNif.text_run(:nope) end
    assert_raise ArgumentError, fn -> TextNif.ascii?([1, 2]) end
    assert_raise ArgumentError, fn -> TextNif.ascii_cells("ok", 0x10000, 0, 0) end
    assert_raise ArgumentError, fn -> TextNif.ascii_cells("ok", 0, 0, -1) end
  end

  # Every codepoint between two letters: the table (Unicode 15.0 to 17.0 and
  # glibc's widths) must agree with OTP's segmentation and Unicode.width/1, on
  # whatever OTP runs the test.
  test "every codepoint agrees with Elixir" do
    text =
      for cp <- Enum.concat(0..0xD7FF, 0xE000..0x10FFFF), into: "a", do: <<cp::utf8, ?a>>

    assert nif(text) == elixir(text)
  end

  # The pieces that make clusters, mixed at random.
  defp piece do
    StreamData.member_of([
      "a",
      "Z",
      " ",
      "é",
      "ñ",
      "漢",
      "字",
      "✓",
      "→",
      "🚀",
      "👍",
      # combining marks, a skin tone, ZWJ, variation selector 16
      "\u{0301}",
      "\u{0308}",
      "🏽",
      "\u{200D}",
      "\u{FE0F}",
      # regional indicators (🇯 🇵 🇺 🇸)
      "\u{1F1EF}",
      "\u{1F1F5}",
      "\u{1F1FA}",
      "\u{1F1F8}",
      # Hangul: a syllable, and leading, vowel and trailing jamo
      "가",
      "\u{1100}",
      "\u{1161}",
      "\u{11A8}",
      # Devanagari: consonants and the virama that joins them (GB9c)
      "क",
      "ष",
      "\u{094D}",
      # a prepended concatenation mark, a spacing mark
      "\u{0600}",
      "\u{0903}"
    ])
  end

  property "any mix of joining pieces gives Elixir's clusters and widths" do
    check all(pieces <- StreamData.list_of(piece(), max_length: 30)) do
      text = Enum.join(pieces)
      assert nif(text) == elixir(text)
    end
  end
end

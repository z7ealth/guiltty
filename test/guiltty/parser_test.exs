defmodule Guiltty.ParserTest do
  use ExUnit.Case, async: true

  alias Guiltty.Parser

  doctest Parser

  defp parse(bytes), do: bytes |> then(&Parser.feed(Parser.new(), &1)) |> elem(1)

  # Same bytes split at every possible point must give the same commands,
  # once adjacent prints are merged.
  defp parse_split(bytes, at) do
    <<a::binary-size(^at), b::binary>> = bytes
    {p, c1} = Parser.feed(Parser.new(), a)
    {_p, c2} = Parser.feed(p, b)
    merge(c1 ++ c2)
  end

  defp merge([{:print, a}, {:print, b} | rest]), do: merge([{:print, a <> b} | rest])
  defp merge([c | rest]), do: [c | merge(rest)]
  defp merge([]), do: []

  test "controls" do
    assert parse("a\r\n\b\tb\a") == [{:print, "a"}, :cr, :lf, :bs, :ht, {:print, "b"}]
  end

  test "skips CSI sequences up to the final byte" do
    assert parse("\e[01;31mred\e[0m\e[?2004h") == [{:print, "red"}]
  end

  test "skips OSC ended by BEL or ST" do
    assert parse("\e]0;title\ax\e]2;t\e\\y") == [{:print, "x"}, {:print, "y"}]
  end

  test "skips the openSUSE prompt's title sequences" do
    bytes = "\e7\e]2;me@host:~\a\e]1;host\a\e8me@host:~> "
    assert parse(bytes) == [{:print, "me@host:~> "}]
  end

  test "skips two-byte escapes and charset designations" do
    assert parse("\e7a\e(Bb\e=c") == [{:print, "a"}, {:print, "b"}, {:print, "c"}]
  end

  test "CAN aborts a sequence" do
    assert parse("\e[12\x18ok") == [{:print, "ok"}]
  end

  test "each UTF-8 character becomes one ?" do
    assert parse("señor ✓") == [{:print, "se"}, {:print, "?"}, {:print, "or "}, {:print, "?"}]
  end

  test "any split point gives the same result" do
    bytes = "\e7\e]2;t\a\e8$ \e[1mls\e[0m\r\nfoo\tbar\e]0;x\e\\ñ!\r\n"
    expected = merge(parse(bytes))

    for at <- 0..byte_size(bytes) do
      assert parse_split(bytes, at) == expected, "split at #{at}"
    end
  end
end

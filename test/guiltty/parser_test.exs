defmodule Guiltty.ParserTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Guiltty.Parser

  doctest Parser

  defp parse(bytes), do: bytes |> then(&Parser.feed(Parser.new(), &1)) |> elem(1)

  defp parse_chunks(chunks) do
    {_p, cmds} =
      Enum.reduce(chunks, {Parser.new(), []}, fn chunk, {p, acc} ->
        {p, cmds} = Parser.feed(p, chunk)
        {p, acc ++ cmds}
      end)

    merge(cmds)
  end

  # Splitting text can split one print into two; merge them back to compare.
  defp merge([{:print, a}, {:print, b} | rest]), do: merge([{:print, a <> b} | rest])
  defp merge([c | rest]), do: [c | merge(rest)]
  defp merge([]), do: []

  describe "C0 controls" do
    test "the ones a terminal acts on" do
      assert parse("a\r\n\b\tb\a") == [{:print, "a"}, :cr, :lf, :bs, :ht, {:print, "b"}]
      assert parse("\v\f") == [:lf, :lf]
    end

    test "are executed in the middle of a CSI sequence" do
      assert parse("\e[1\r2H") == [:cr, {:csi, nil, [12], "", ?H}]
    end
  end

  describe "CSI" do
    test "parameters" do
      assert parse("\e[H") == [{:csi, nil, [], "", ?H}]
      assert parse("\e[5;10H") == [{:csi, nil, [5, 10], "", ?H}]
      assert parse("\e[;5H") == [{:csi, nil, [nil, 5], "", ?H}]
      assert parse("\e[01;31m") == [{:csi, nil, [1, 31], "", ?m}]
    end

    test "private markers and intermediates" do
      assert parse("\e[?25l") == [{:csi, ??, [25], "", ?l}]
      assert parse("\e[?1049h") == [{:csi, ??, [1049], "", ?h}]
      assert parse("\e[>c") == [{:csi, ?>, [], "", ?c}]
      assert parse("\e[2 q") == [{:csi, nil, [2], " ", ?q}]
    end

    test "colon sub-parameters" do
      assert parse("\e[38:2::255:0:10m") == [{:csi, nil, [[38, 2, nil, 255, 0, 10]], "", ?m}]
      assert parse("\e[4:3;1m") == [{:csi, nil, [[4, 3], 1], "", ?m}]
    end

    test "malformed sequences are skipped whole" do
      assert parse("\e[1?2hX") == [{:print, "X"}]
      assert parse("\e[ 1hX") == [{:print, "X"}]
    end

    test "huge values and too many parameters are capped" do
      [{:csi, nil, [n], "", ?m}] = parse("\e[99999999999m")
      assert n == 65_535
      [{:csi, nil, params, "", ?m}] = parse("\e[" <> Enum.join(1..100, ";") <> "m")
      assert length(params) == 32
    end

    test "CAN aborts and ESC restarts" do
      assert parse("\e[12\x18ok") == [{:print, "ok"}]
      assert parse("\e[12\e[3m") == [{:csi, nil, [3], "", ?m}]
    end
  end

  describe "ESC" do
    test "two-byte sequences and intermediates" do
      assert parse("\e7\eM\ec") == [{:esc, "", ?7}, {:esc, "", ?M}, {:esc, "", ?c}]
      assert parse("\e(B") == [{:esc, "(", ?B}]
    end
  end

  describe "strings" do
    test "OSC ends with BEL or ST" do
      assert parse("\e]0;title\ax") == [{:osc, "0;title"}, {:print, "x"}]
      assert parse("\e]2;t\e\\y") == [{:osc, "2;t"}, {:print, "y"}]
    end

    test "ESC that isn't ST ends the OSC and starts a sequence" do
      assert parse("\e]0;t\e[1m") == [{:osc, "0;t"}, {:csi, nil, [1], "", ?m}]
    end

    test "DCS, SOS, PM and APC are dropped" do
      assert parse("\ePq#0;2;0;0;0\e\\a") == [{:print, "a"}]
      assert parse("\e_app\e\\b\eXsos\e\\c") == [{:print, "b"}, {:print, "c"}]
    end

    test "OSC data is capped" do
      [{:osc, data}] = parse("\e]0;" <> String.duplicate("x", 10_000) <> "\a")
      assert byte_size(data) == 4096
    end
  end

  test "each UTF-8 character becomes one ?" do
    assert parse("señor ✓") == [{:print, "se"}, {:print, "?"}, {:print, "or "}, {:print, "?"}]
  end

  test "the openSUSE prompt" do
    cmds = parse("\e7\e]2;me@host:~\a\e]1;host\a\e8me@host:~> ")
    assert [{:esc, "", ?7}, {:osc, "2;me@host:~"}, {:osc, "1;host"}, {:esc, "", ?8} | _] = cmds
    assert List.last(cmds) == {:print, "me@host:~> "}
  end

  property "never crashes on random bytes" do
    check all(bytes <- binary()) do
      assert is_list(parse(bytes))
    end
  end

  property "any chunking gives the same commands" do
    sample =
      StreamData.member_of([
        "\e[01;31m",
        "\e[38:2::1:2:3m",
        "\e]0;title\a",
        "\e]2;x\e\\",
        "\ePdata\e\\",
        "\e7",
        "\e[?25l",
        "plain text",
        "\r\n",
        "\t",
        "ñ",
        "\e[",
        "5;"
      ])

    check all(
            parts <- list_of(sample, max_length: 20),
            bytes = IO.iodata_to_binary(parts),
            cuts <- list_of(integer(0..max(byte_size(bytes), 1)), max_length: 6)
          ) do
      expected = parse_chunks([bytes])
      assert parse_chunks(split(bytes, cuts)) == expected
    end
  end

  defp split(bytes, cuts) do
    cuts
    |> Enum.map(&min(&1, byte_size(bytes)))
    |> Enum.uniq()
    |> Enum.sort()
    |> then(&([0] ++ &1 ++ [byte_size(bytes)]))
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> binary_part(bytes, a, b - a) end)
  end
end

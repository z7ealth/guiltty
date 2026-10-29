defmodule Guiltty.KeymapTest do
  use ExUnit.Case, async: true

  alias Guiltty.Keymap

  @ctrl 0x0040
  @shift 0x0001
  @alt 0x0100

  test "text is sent as typed" do
    assert Keymap.to_bytes({:text, "a"}) == "a"
    assert Keymap.to_bytes({:text, "ñ"}) == "ñ"
  end

  test "special keys" do
    assert Keymap.to_bytes({:key, 0x0D, 0}) == "\r"
    assert Keymap.to_bytes({:key, 0x40000058, 0}) == "\r"
    assert Keymap.to_bytes({:key, 0x08, 0}) == <<0x7F>>
    assert Keymap.to_bytes({:key, 0x09, 0}) == "\t"
    assert Keymap.to_bytes({:key, 0x1B, 0}) == <<0x1B>>
  end

  test "Ctrl+A..Z become 0x01..0x1A" do
    assert Keymap.to_bytes({:key, ?a, @ctrl}) == <<0x01>>
    assert Keymap.to_bytes({:key, ?c, @ctrl}) == <<0x03>>
    assert Keymap.to_bytes({:key, ?z, @ctrl ||| @shift}) == <<0x1A>>
  end

  test "plain letters, Ctrl+Alt and unknown keys produce nothing" do
    # Plain letters arrive as text events; the key event must not double them.
    assert Keymap.to_bytes({:key, ?a, 0}) == nil
    assert Keymap.to_bytes({:key, ?a, @ctrl ||| @alt}) == nil
    assert Keymap.to_bytes({:key, 0x4000003A, 0}) == nil
  end

  defp a ||| b, do: Bitwise.bor(a, b)
end

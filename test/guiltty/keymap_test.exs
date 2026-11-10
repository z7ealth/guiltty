defmodule Guiltty.KeymapTest do
  use ExUnit.Case, async: true

  alias Guiltty.Keymap

  @shift 0x0001
  @ctrl 0x0040
  @alt 0x0100
  @lgui 0x0400

  @normal %{
    cursor_keys: :normal,
    keypad: :numeric,
    bracketed_paste: false,
    mouse: nil,
    mouse_sgr: false
  }
  @app %{@normal | cursor_keys: :application, keypad: :application}

  @up 0x40000052
  @right 0x4000004F
  @home 0x4000004A
  @end_ 0x4000004D
  @page_up 0x4000004B
  @delete 0x7F
  @f1 0x4000003A
  @f5 0x4000003E
  @f12 0x40000045
  @kp_enter 0x40000058
  @caps_lock 0x40000039

  defp key(code, mods \\ 0, input \\ @normal), do: Keymap.to_bytes({:key, code, mods}, input)

  test "text is sent as typed" do
    assert Keymap.to_bytes({:text, "a"}, @normal) == "a"
    assert Keymap.to_bytes({:text, "ñ"}, @normal) == "ñ"
  end

  test "Enter, Backspace, Tab, Shift+Tab, Escape" do
    assert key(0x0D) == "\r"
    assert key(0x08) == <<0x7F>>
    assert key(0x09) == "\t"
    assert key(0x09, @shift) == "\e[Z"
    assert key(0x1B) == "\e"
  end

  test "Ctrl+A..Z become 0x01..0x1A" do
    assert key(?a, @ctrl) == <<0x01>>
    assert key(?c, @ctrl) == <<0x03>>
    assert key(?z, @ctrl ||| @shift) == <<0x1A>>
  end

  test "arrows and Home/End follow the cursor-key mode" do
    assert key(@up) == "\e[A"
    assert key(@up, 0, @app) == "\eOA"
    assert key(@home) == "\e[H"
    assert key(@end_, 0, @app) == "\eOF"
  end

  test "modifiers add a parameter, in either mode" do
    assert key(@right, @ctrl) == "\e[1;5C"
    assert key(@right, @ctrl, @app) == "\e[1;5C"
    assert key(@up, @shift ||| @alt) == "\e[1;4A"
    assert key(@page_up, @shift) == "\e[5;2~"
  end

  test "editing and paging keys" do
    assert key(0x40000049) == "\e[2~"
    assert key(@delete) == "\e[3~"
    assert key(@page_up) == "\e[5~"
    assert key(0x4000004E) == "\e[6~"
  end

  test "function keys" do
    assert key(@f1) == "\eOP"
    assert key(@f1, @ctrl) == "\e[1;5P"
    assert key(@f5) == "\e[15~"
    assert key(@f12) == "\e[24~"
    assert key(@f5, @shift) == "\e[15;2~"
  end

  test "keypad Enter in application keypad mode" do
    assert key(@kp_enter) == "\r"
    assert key(@kp_enter, 0, @app) == "\eOM"
  end

  test "plain letters and unknown keys produce nothing" do
    # Plain letters arrive as text events; the key event must not double them.
    assert key(?a) == nil
    assert key(@caps_lock) == nil
  end

  describe "Ctrl and Alt, as xterm sends them" do
    test "Ctrl with punctuation and the digit row" do
      assert key(?\s, @ctrl) == <<0>>
      assert key(?[, @ctrl) == <<0x1B>>
      assert key(?\\, @ctrl) == <<0x1C>>
      assert key(?], @ctrl) == <<0x1D>>
      assert key(?6, @ctrl) == <<0x1E>>
      assert key(?-, @ctrl) == <<0x1F>>
      assert key(?2, @ctrl) == <<0>>
      assert key(?8, @ctrl) == <<0x7F>>
    end

    test "left Alt is ESC, in front of what the key would send" do
      left_alt = 0x0100
      assert Keymap.to_bytes({:key, ?b, left_alt, %{kind: :press, shifted: ?b}}) == "\eb"
      assert Keymap.to_bytes({:key, ?b, left_alt ||| 1, %{kind: :press, shifted: ?B}}) == "\eB"
      assert Keymap.to_bytes({:key, ?1, left_alt ||| 1, %{kind: :press, shifted: ?!}}) == "\e!"
      assert key(?a, @ctrl ||| left_alt) == <<0x1B, 1>>
      assert key(0x08, left_alt) == <<0x1B, 0x7F>>
      assert key(0x0D, left_alt) == "\e\r"
    end

    test "right Alt is AltGr: its text arrives as text" do
      assert Keymap.to_bytes({:key, ?q, 0x0200, %{kind: :press, shifted: ?q}}) == nil
    end

    test "a key release is nothing, without the Kitty protocol" do
      assert Keymap.to_bytes({:key, 0x0D, 0, %{kind: :release, shifted: 0x0D}}) == nil
    end

    test "modes change Enter and Backspace" do
      input = Map.merge(Guiltty.Grid.default_input(), %{newline_mode: true, backarrow_bs: true})
      assert Keymap.to_bytes({:key, 0x0D, 0}, input) == "\r\n"
      assert Keymap.to_bytes({:key, 0x08, 0}, input) == <<0x08>>
    end
  end

  describe "the Kitty keyboard protocol" do
    defp kitty(flags, key, mods \\ 0, kind \\ :press, shifted \\ nil) do
      input = %{Guiltty.Grid.default_input() | kitty: flags}
      Keymap.to_bytes({:key, key, mods, %{kind: kind, shifted: shifted || key}}, input)
    end

    test "flag 1: what was ambiguous is spelled out" do
      assert kitty(1, 0x1B) == "\e[27u"
      assert kitty(1, ?i, @ctrl) == "\e[105;5u"
      assert kitty(1, ?a, 0x0100) == "\e[97;3u"
      assert kitty(1, 0x0D, @shift) == "\e[13;2u"
      assert kitty(1, 0x09, @shift) == "\e[9;2u"
    end

    test "flag 1: plain keys stay as they were, and typing stays text" do
      assert kitty(1, 0x0D) == "\r"
      assert kitty(1, 0x09) == "\t"
      assert kitty(1, 0x08) == <<0x7F>>
      assert kitty(1, ?a) == nil
      assert kitty(1, ?a, @shift) == nil
      assert kitty(1, 0x40000052) == "\e[A"
      assert kitty(1, 0x40000052, @ctrl) == "\e[1;5A"
    end

    test "flag 2: repeats and releases" do
      assert kitty(1 + 2, 0x1B, 0, :release) == "\e[27;1:3u"
      assert kitty(1 + 2, ?i, @ctrl, :repeat) == "\e[105;5:2u"
      assert kitty(1 + 2, 0x40000052, 0, :release) == "\e[1;1:3A"
      # Enter's release stays quiet, so `reset` can still be typed blind.
      assert kitty(1 + 2, 0x0D, 0, :release) == nil
      assert kitty(1, 0x1B, 0, :release) == nil
    end

    test "flag 8: every key is an escape code, text and Shift too" do
      assert kitty(8, ?a) == "\e[97u"
      assert kitty(8, ?a, @shift, :press, ?A) == "\e[97;2u"
      assert kitty(8, 0x0D) == "\e[13u"
      assert kitty(8, 0x08) == "\e[127u"
      assert kitty(8, 0x400000E1, @shift) == "\e[57441;2u"
      assert kitty(1, 0x400000E1, @shift) == nil
    end

    test "function keys" do
      assert kitty(1, 0x4000003A + 2) == "\e[13~"
      assert kitty(1, 0x4000003A, @ctrl) == "\e[1;5P"
      assert kitty(1, 0x4B + 0x40000000, @shift) == "\e[5;2~"
    end
  end

  describe "mouse encodings" do
    defp mouse_with(modes, kind \\ :press, cell_pixels \\ nil) do
      input = Map.merge(Guiltty.Grid.default_input(), modes)
      Keymap.mouse({:mouse, kind, 0, 300, 2, 0, 1}, input, cell_pixels)
    end

    test "mode 9 is presses alone" do
      assert mouse_with(%{mouse: 9, mouse_sgr: true}) == "\e[<0;301;3M"
      assert mouse_with(%{mouse: 9, mouse_sgr: true}, :release) == nil
    end

    test "1005 writes large coordinates in UTF-8" do
      assert mouse_with(%{mouse: 1000, mouse_utf8: true}) == <<"\e[M", 32, 333::utf8, 35::utf8>>
    end

    test "1015 is decimal" do
      assert mouse_with(%{mouse: 1000, mouse_urxvt: true}) == "\e[32;301;3M"
    end

    test "1016 is SGR in pixels, at the cell's middle" do
      assert mouse_with(%{mouse: 1000, mouse_pixels: true}, :press, {10, 20}) == "\e[<0;3006;51M"
      assert mouse_with(%{mouse: 1000, mouse_pixels: true, mouse_sgr: true}) == "\e[<0;301;3M"
    end
  end

  describe "paste" do
    test "newlines become CR" do
      assert Keymap.paste("a\nb\r\nc", @normal) == "a\rb\rc"
    end

    test "bracketed paste wraps the text" do
      bracketed = %{@normal | bracketed_paste: true}
      assert Keymap.paste("ls\nrm -rf x", bracketed) == "\e[200~ls\rrm -rf x\e[201~"
    end

    test "markers inside the pasted text can't end the paste early" do
      bracketed = %{@normal | bracketed_paste: true}
      evil = "echo hi\e[201~rm -rf ~\n"
      assert Keymap.paste(evil, bracketed) == "\e[200~echo hirm -rf ~\r\e[201~"
    end
  end

  describe "mouse" do
    defp mouse(kind, button, input, mods \\ 0),
      do: Keymap.mouse({:mouse, kind, button, 4, 2, mods, 1}, input)

    test "nothing unless the program asked" do
      assert mouse(:press, 0, @normal) == nil
    end

    test "SGR encoding" do
      input = %{@normal | mouse: 1000, mouse_sgr: true}
      assert mouse(:press, 0, input) == "\e[<0;5;3M"
      assert mouse(:release, 0, input) == "\e[<0;5;3m"
      assert mouse(:press, 2, input, @ctrl) == "\e[<18;5;3M"
      assert mouse(:wheel, 1, input) == "\e[<65;5;3M"
    end

    test "motion depends on the mode" do
      clicks = %{@normal | mouse: 1000, mouse_sgr: true}
      drags = %{clicks | mouse: 1002}
      all = %{clicks | mouse: 1003}
      assert mouse(:motion, 0, clicks) == nil
      assert mouse(:motion, 0, drags) == "\e[<32;5;3M"
      assert mouse(:motion, 3, drags) == nil
      assert mouse(:motion, 3, all) == "\e[<35;5;3M"
    end

    test "X10 encoding without 1006" do
      input = %{@normal | mouse: 1000}
      assert mouse(:press, 0, input) == <<"\e[M", 32, 37, 35>>
      assert mouse(:release, 0, input) == <<"\e[M", 35, 37, 35>>
    end
  end

  describe "bindings" do
    # SDLK_F23: F13-F24 sit apart from F1-F12 in SDL's numbering.
    @f23 0x40000072

    test "the laptop AI key: Left Shift, Left Super and F23 at once" do
      assert {:ok, binding} = Keymap.parse_key("super+shift+f23")
      assert binding == {@f23, MapSet.new([:super, :shift])}
      assert Keymap.matches?({:key, @f23, @lgui ||| @shift}, binding)
      refute Keymap.matches?({:key, @f23, @shift}, binding)
    end

    test "F13 to F24 have names" do
      assert Keymap.parse_key("f13") == {:ok, {0x40000068, MapSet.new()}}
      assert Keymap.parse_key("f24") == {:ok, {0x40000073, MapSet.new()}}
      assert Keymap.parse_key("f25") == :error
    end

    test "Super held is part of the chord" do
      {:ok, new_tab} = Keymap.parse_key("ctrl+shift+t")
      assert Keymap.matches?({:key, ?t, @ctrl ||| @shift}, new_tab)
      refute Keymap.matches?({:key, ?t, @ctrl ||| @shift ||| @lgui}, new_tab)
    end
  end

  defp a ||| b, do: Bitwise.bor(a, b)
end

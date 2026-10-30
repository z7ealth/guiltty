defmodule Guiltty.KeymapTest do
  use ExUnit.Case, async: true

  alias Guiltty.Keymap

  @shift 0x0001
  @ctrl 0x0040
  @alt 0x0100

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

  test "plain letters, Ctrl+Alt and unknown keys produce nothing" do
    # Plain letters arrive as text events; the key event must not double them.
    assert key(?a) == nil
    assert key(?a, @ctrl ||| @alt) == nil
    assert key(@caps_lock) == nil
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

  defp a ||| b, do: Bitwise.bor(a, b)
end

defmodule Guiltty.Keymap do
  @moduledoc """
  Turns renderer events (keys, text, paste, mouse) into the bytes a terminal
  sends, following xterm. What some keys send depends on modes the program
  set (`Guiltty.Grid`'s `input` map).

  ## Text and keys

  Printable characters arrive as `{:text, utf8}` (SDL's text input, which
  already applied Shift and the keyboard layout) and are sent as is.
  Everything else arrives as `{:key, keycode, mods}` with SDL keycodes:

  | Key                | Bytes                                  |
  |--------------------|----------------------------------------|
  | Enter              | `\\r` (`ESC O M` on the keypad in application mode) |
  | Backspace          | `0x7F` (DEL)                           |
  | Tab, Shift+Tab     | `\\t`, `CSI Z`                          |
  | Escape             | `ESC`                                  |
  | Ctrl+A .. Ctrl+Z   | `0x01` .. `0x1A`                       |
  | arrows             | `CSI A`..`D`, or `ESC O A`..`D` in application cursor-key mode |
  | Home, End          | `CSI H`, `CSI F` (`ESC O H`/`F` in application mode) |
  | Insert, Delete     | `CSI 2 ~`, `CSI 3 ~`                    |
  | PgUp, PgDn         | `CSI 5 ~`, `CSI 6 ~`                    |
  | F1 .. F4           | `ESC O P` .. `ESC O S`                 |
  | F5 .. F12          | `CSI 15 ~` .. `CSI 24 ~` (skipping 16 and 22) |

  With Shift, Alt or Ctrl held, the special keys carry a modifier
  parameter m = 1 + Shift(1) + Alt(2) + Ctrl(4): Ctrl+Right is `CSI 1;5C`,
  Shift+PgUp is `CSI 5;2~`.

  Ctrl+C is just byte `0x03`: the kernel's line discipline is what turns it
  into SIGINT for the foreground job.
  """

  import Bitwise

  # SDL3 keycodes (SDL_keycode.h). Letters are their lowercase ASCII.
  @return 0x0D
  @backspace 0x08
  @tab 0x09
  @escape 0x1B
  @delete 0x7F
  @kp_enter 0x40000058
  @f1 0x4000003A
  @f12 0x40000045
  @insert 0x40000049
  @home 0x4000004A
  @page_up 0x4000004B
  @end_ 0x4000004D
  @page_down 0x4000004E
  @right 0x4000004F
  @left 0x40000050
  @down 0x40000051
  @up 0x40000052

  # SDL_Keymod bits
  @kmod_shift 0x0003
  @kmod_ctrl 0x00C0
  @kmod_alt 0x0300

  # Keys that end in a letter: CSI X normally, SS3 X in application mode.
  @cursor_keys %{@up => ?A, @down => ?B, @right => ?C, @left => ?D, @home => ?H, @end_ => ?F}

  # Keys that end in ~: CSI n ~.
  @tilde_keys %{@insert => 2, @delete => 3, @page_up => 5, @page_down => 6}

  # F1-F4 are SS3 P..S; F5-F12 are CSI n ~ with gaps (xterm's numbering).
  @function_keys Enum.zip(@f1..@f12, [?P, ?Q, ?R, ?S, 15, 17, 18, 19, 20, 21, 23, 24])
                 |> Map.new()

  @default_input %{
    cursor_keys: :normal,
    keypad: :numeric,
    bracketed_paste: false,
    mouse: nil,
    mouse_sgr: false
  }

  @spec to_bytes(Guiltty.Window.Protocol.event(), map()) :: binary() | nil
  def to_bytes(event, input \\ @default_input)

  def to_bytes({:text, text}, _input), do: text

  def to_bytes({:key, key, mods}, input) do
    m = modifier(mods)

    cond do
      key in ?a..?z and (mods &&& @kmod_ctrl) != 0 and (mods &&& @kmod_alt) == 0 ->
        <<key - ?a + 1>>

      key == @kp_enter and input.keypad == :application ->
        "\eOM"

      key in [@return, @kp_enter] ->
        "\r"

      key == @backspace ->
        <<0x7F>>

      key == @tab and (mods &&& @kmod_shift) != 0 ->
        "\e[Z"

      key == @tab ->
        "\t"

      key == @escape ->
        "\e"

      Map.has_key?(@cursor_keys, key) ->
        cursor_key(@cursor_keys[key], m, input.cursor_keys)

      Map.has_key?(@tilde_keys, key) ->
        tilde(@tilde_keys[key], m)

      Map.has_key?(@function_keys, key) ->
        function_key(@function_keys[key], m)

      true ->
        nil
    end
  end

  def to_bytes(_event, _input), do: nil

  defp modifier(mods) do
    1 + if((mods &&& @kmod_shift) != 0, do: 1, else: 0) +
      if((mods &&& @kmod_alt) != 0, do: 2, else: 0) +
      if((mods &&& @kmod_ctrl) != 0, do: 4, else: 0)
  end

  defp cursor_key(letter, 1, :application), do: <<"\eO", letter>>
  defp cursor_key(letter, 1, :normal), do: <<"\e[", letter>>
  defp cursor_key(letter, m, _mode), do: <<"\e[1;#{m}", letter>>

  defp tilde(n, 1), do: "\e[#{n}~"
  defp tilde(n, m), do: "\e[#{n};#{m}~"

  defp function_key(letter, 1) when letter in ?P..?S, do: <<"\eO", letter>>
  defp function_key(letter, m) when letter in ?P..?S, do: <<"\e[1;#{m}", letter>>
  defp function_key(n, m), do: tilde(n, m)

  ## Bindings

  @key_names Map.merge(
               %{
                 "tab" => @tab,
                 "enter" => @return,
                 "escape" => @escape,
                 "backspace" => @backspace,
                 "delete" => @delete,
                 "insert" => @insert,
                 "home" => @home,
                 "end" => @end_,
                 "page_up" => @page_up,
                 "page_down" => @page_down,
                 "up" => @up,
                 "down" => @down,
                 "left" => @left,
                 "right" => @right
               },
               Map.new(1..12, fn n -> {"f#{n}", @f1 + n - 1} end)
             )

  @doc """
  Parses a key name like `"ctrl+shift+t"` into `{keycode, modifiers}`,
  where modifiers is a set of `:ctrl`, `:shift` and `:alt`. Single letters
  and digits are their own keycode.
  """
  @spec parse_key(binary()) :: {:ok, {non_neg_integer(), MapSet.t()}} | :error
  def parse_key(name) do
    {mods, [key]} = name |> String.downcase() |> String.split("+") |> Enum.split(-1)

    with true <- Enum.all?(mods, &(&1 in ~w(ctrl shift alt))),
         {:ok, code} <- keycode(key) do
      {:ok, {code, MapSet.new(mods, &String.to_existing_atom/1)}}
    else
      _ -> :error
    end
  end

  defp keycode(<<c>>) when c in ?a..?z or c in ?0..?9, do: {:ok, c}
  defp keycode(name), do: Map.fetch(@key_names, name)

  @doc "Whether a key event matches a parsed binding."
  def matches?({:key, code, mods}, {code, wanted}), do: modifier_set(mods) == wanted
  def matches?(_event, _binding), do: false

  defp modifier_set(mods) do
    [ctrl: @kmod_ctrl, shift: @kmod_shift, alt: @kmod_alt]
    |> Enum.filter(fn {_name, mask} -> (mods &&& mask) != 0 end)
    |> MapSet.new(fn {name, _mask} -> name end)
  end

  ## Paste

  @doc """
  What to send for pasted text. Line endings become CR, like pressing Enter.
  In bracketed paste mode (2004) the text is wrapped in `ESC [ 200 ~` and
  `ESC [ 201 ~`, so the program knows it was pasted, not typed; any such
  markers inside the text are removed first, or a crafted clipboard could
  end the paste early and run the rest as typed commands.
  """
  @spec paste(binary(), map()) :: binary()
  def paste(text, input \\ @default_input) do
    text = String.replace(text, ["\r\n", "\n"], "\r")

    if input.bracketed_paste,
      do: "\e[200~" <> String.replace(text, ["\e[200~", "\e[201~"], "") <> "\e[201~",
      else: text
  end

  ## Mouse

  @doc """
  What to send for a mouse event, or nil when the program didn't ask for
  it. `event` is `{:mouse, kind, button, col, row, mods}`, with `kind` one
  of `:press`, `:release`, `:motion`, `:wheel`, `button` 0-2 (left, middle,
  right; 3 = none held) or for the wheel 0 (up) and 1 (down), and 0-based
  cell coordinates.

  Mode 1000 reports clicks and the wheel, 1002 also motion while a button
  is held, 1003 all motion. The encoding is SGR (mode 1006,
  `CSI < b ; x ; y M` or `m` on release) or else the original X10 one.
  """
  @spec mouse(tuple(), map()) :: binary() | nil
  def mouse({:mouse, kind, button, col, row, mods}, input) do
    if reported?(kind, button, input.mouse) do
      code = button_code(kind, button) ||| mouse_mods(mods)
      encode_mouse(code, kind, col, row, input.mouse_sgr)
    end
  end

  defp reported?(_kind, _button, nil), do: false
  defp reported?(:motion, 3, mode), do: mode == 1003
  defp reported?(:motion, _held, mode), do: mode in [1002, 1003]
  defp reported?(_kind, _button, _mode), do: true

  defp button_code(:wheel, dir), do: 64 + dir
  defp button_code(:motion, button), do: 32 + button
  defp button_code(_press_or_release, button), do: button

  defp mouse_mods(mods) do
    if((mods &&& @kmod_shift) != 0, do: 4, else: 0) |||
      if((mods &&& @kmod_alt) != 0, do: 8, else: 0) |||
      if((mods &&& @kmod_ctrl) != 0, do: 16, else: 0)
  end

  defp encode_mouse(code, kind, col, row, true) do
    "\e[<#{code};#{col + 1};#{row + 1}" <> if(kind == :release, do: "m", else: "M")
  end

  # X10: each value is a byte offset by 32, so coordinates stop at 222.
  defp encode_mouse(code, kind, col, row, false) do
    code = if kind == :release, do: 3 ||| (code &&& 0b11100), else: code

    if col < 223 and row < 223,
      do: <<"\e[M", 32 + code, 33 + col, 33 + row>>
  end
end

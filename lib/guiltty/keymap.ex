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

  Ctrl and punctuation follow xterm too: Ctrl+Space is NUL, Ctrl+[ is ESC,
  Ctrl+\\ Ctrl+] Ctrl+^ Ctrl+_ are `0x1C`..`0x1F`, and the digit row gives
  the same ones. Left Alt puts an ESC in front of what the key would send, so
  Alt+b is `ESC b`, which is how readline moves back a word. Right Alt doesn't:
  on most layouts it's AltGr, which types characters.

  Ctrl+C is just byte `0x03`: the kernel's line discipline is what turns it
  into SIGINT for the foreground job.

  ## The Kitty keyboard protocol

  The bytes above can't tell Ctrl+I from Tab, or Shift+Enter from Enter, and
  Esc looks like the start of a sequence. A program that asks (`CSI > flags u`,
  in `input.kitty`) gets keys spelled out instead, as `CSI code ; mods u`:

  | Flag | Asks for                                     |
  |------|----------------------------------------------|
  | 1    | no more ambiguity: Esc, and Ctrl or Alt with any key, are escape codes |
  | 2    | whether a key was pressed, repeated or released |
  | 8    | every key as an escape code, text too        |

  Flags 4 (alternate keys) and 16 (text as codepoints) aren't offered: a
  program that asks can see that from its answer to `CSI ? u`.
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
  @kmod_lalt 0x0100
  @kmod_gui 0x0C00
  @kmod_num 0x1000
  @kmod_caps 0x2000

  # Keys that end in a letter: CSI X normally, SS3 X in application mode.
  @cursor_keys %{@up => ?A, @down => ?B, @right => ?C, @left => ?D, @home => ?H, @end_ => ?F}

  # Keys that end in ~: CSI n ~.
  @tilde_keys %{@insert => 2, @delete => 3, @page_up => 5, @page_down => 6}

  # F1-F4 are SS3 P..S; F5-F12 are CSI n ~ with gaps (xterm's numbering).
  @function_keys Enum.zip(@f1..@f12, [?P, ?Q, ?R, ?S, 15, 17, 18, 19, 20, 21, 23, 24])
                 |> Map.new()

  @default_input Guiltty.Grid.default_input()

  # Ctrl and a key that isn't a letter: the C0 control xterm sends for it.
  @ctrl_keys %{
    ?\s => 0x00,
    ?2 => 0x00,
    ?@ => 0x00,
    ?3 => 0x1B,
    ?[ => 0x1B,
    ?4 => 0x1C,
    ?\\ => 0x1C,
    ?5 => 0x1D,
    ?] => 0x1D,
    ?6 => 0x1E,
    ?^ => 0x1E,
    ?7 => 0x1F,
    ?- => 0x1F,
    ?_ => 0x1F,
    ?/ => 0x1F,
    ?8 => 0x7F
  }

  @spec to_bytes(Guiltty.Window.Protocol.event() | tuple(), map()) :: binary() | nil
  def to_bytes(event, input \\ @default_input)

  def to_bytes({:text, text}, _input), do: text

  def to_bytes({:key, key, mods}, input),
    do: to_bytes({:key, key, mods, %{kind: :press, shifted: key}}, input)

  def to_bytes({:key, key, mods, extra}, input) do
    case Map.get(input, :kitty, 0) do
      0 -> if extra.kind == :release, do: nil, else: legacy(key, mods, extra, input)
      flags -> kitty(key, mods, extra, flags, input)
    end
  end

  def to_bytes(_event, _input), do: nil

  defp legacy(key, mods, extra, input) do
    meta = if (mods &&& @kmod_lalt) != 0, do: "\e", else: ""
    ctrl? = (mods &&& @kmod_ctrl) != 0
    m = modifier(mods)

    cond do
      ctrl? and key in ?a..?z ->
        <<meta::binary, key - ?a + 1>>

      ctrl? and is_map_key(@ctrl_keys, key) ->
        <<meta::binary, @ctrl_keys[key]>>

      key == @kp_enter and input.keypad == :application ->
        "\eOM"

      key in [@return, @kp_enter] ->
        meta <> if(Map.get(input, :newline_mode, false), do: "\r\n", else: "\r")

      key == @backspace ->
        erase = if Map.get(input, :backarrow_bs, false), do: 0x7F, else: 0x08
        meta <> if(ctrl?, do: <<erase>>, else: <<if(erase == 0x08, do: 0x7F, else: 0x08)>>)

      key == @tab and (mods &&& @kmod_shift) != 0 ->
        meta <> "\e[Z"

      key == @tab ->
        meta <> "\t"

      key == @escape ->
        meta <> "\e"

      meta != "" and not ctrl? and extra.shifted in 0x20..0x7E ->
        <<meta::binary, extra.shifted>>

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

  ## The Kitty keyboard protocol

  # Keys with codes of their own, from the protocol's table of functional keys.
  @kp_keys %{@kp_enter => 57_414}
  @modifier_keys %{
    0x400000E0 => 57_442,
    0x400000E1 => 57_441,
    0x400000E2 => 57_443,
    0x400000E3 => 57_444,
    0x400000E4 => 57_448,
    0x400000E5 => 57_447,
    0x400000E6 => 57_449,
    0x400000E7 => 57_450,
    0x40000039 => 57_358
  }

  # F3 is the odd one: CSI R could be a cursor position report, so it's 13 ~.
  @kitty_function Map.put(@function_keys, @f1 + 2, 13)

  defp kitty(key, mods, %{kind: kind} = extra, flags, input) do
    report_kinds? = (flags &&& 2) != 0
    all_keys? = (flags &&& 8) != 0
    m = kitty_modifier(mods, all_keys?)
    event = if report_kinds?, do: Map.fetch!(%{press: 1, repeat: 2, release: 3}, kind), else: 1
    # With flag 2 alone, Enter, Tab and Backspace still don't report releases,
    # so that typing `reset` blind still works.
    legacy_keys = key in [@return, @kp_enter, @tab, @backspace]

    cond do
      kind == :release and not report_kinds? ->
        nil

      kind == :release and legacy_keys and not all_keys? ->
        nil

      Map.has_key?(@cursor_keys, key) ->
        kitty_letter(@cursor_keys[key], m, event, input)

      Map.has_key?(@tilde_keys, key) ->
        kitty_tilde(@tilde_keys[key], m, event)

      Map.has_key?(@kitty_function, key) ->
        kitty_function(@kitty_function[key], m, event, input)

      Map.has_key?(@modifier_keys, key) ->
        if all_keys?, do: kitty_u(@modifier_keys[key], m, event)

      not all_keys? and legacy_keys and m == 1 ->
        legacy(key, mods, extra, input)

      not all_keys? and key in 0x20..0x7E and (mods &&& (@kmod_ctrl ||| @kmod_lalt)) == 0 ->
        # What it types arrives as text, as it always did.
        if kind == :release, do: kitty_u(key, m, event)

      true ->
        kitty_u(Map.get(@kp_keys, key, kitty_code(key)), m, event)
    end
  end

  # SDL's Backspace is 8 and Delete is 127; the protocol's Backspace is 127.
  defp kitty_code(@backspace), do: 127
  defp kitty_code(key), do: key

  defp kitty_u(code, m, event), do: "\e[#{code}#{kitty_suffix(m, event)}u"
  defp kitty_tilde(n, m, event), do: "\e[#{n}#{kitty_suffix(m, event)}~"

  defp kitty_letter(letter, 1, 1, input),
    do: cursor_key(letter, 1, Map.get(input, :cursor_keys, :normal))

  defp kitty_letter(letter, m, event, _input),
    do: <<"\e[1", kitty_suffix(m, event)::binary, letter>>

  defp kitty_function(letter, m, event, input) when letter in ?P..?S do
    if m == 1 and event == 1,
      do: function_key(letter, 1),
      else: kitty_letter(letter, m, event, input)
  end

  defp kitty_function(n, m, event, _input), do: kitty_tilde(n, m, event)

  defp kitty_suffix(1, 1), do: ""
  defp kitty_suffix(m, 1), do: ";#{m}"
  defp kitty_suffix(m, event), do: ";#{m}:#{event}"

  # Shift 1, Alt 2, Ctrl 4, Super 8; Caps Lock 64 and Num Lock 128 only when
  # every key is reported, where a program can tell what they changed.
  defp kitty_modifier(mods, all_keys?) do
    bits =
      if((mods &&& @kmod_shift) != 0, do: 1, else: 0) +
        if((mods &&& @kmod_alt) != 0, do: 2, else: 0) +
        if((mods &&& @kmod_ctrl) != 0, do: 4, else: 0) +
        if((mods &&& @kmod_gui) != 0, do: 8, else: 0)

    locks =
      if all_keys? do
        if((mods &&& @kmod_caps) != 0, do: 64, else: 0) +
          if (mods &&& @kmod_num) != 0, do: 128, else: 0
      else
        0
      end

    1 + bits + locks
  end

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
                 "right" => @right,
                 # The key that types + without Shift (Latin American, Spanish,
                 # German...). "+" can't be written in a key name: it joins
                 # the parts.
                 "plus" => ?+,
                 "space" => ?\s
               },
               Map.new(1..12, fn n -> {"f#{n}", @f1 + n - 1} end)
             )

  @doc """
  Parses a key name like `"ctrl+shift+t"` into `{keycode, modifiers}`,
  where modifiers is a set of `:ctrl`, `:shift` and `:alt`. Single letters,
  digits and punctuation (`"ctrl+="`) are their own keycode: the key that
  types that character *without* Shift in the current layout. `"plus"` is
  the `+` key.
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

  # Letters, digits and punctuation are their own SDL keycode (the
  # unshifted key: "ctrl+shift+=" is the key that has + on it).
  defp keycode(<<c>>) when c in ?!..?~ and c not in ?A..?Z, do: {:ok, c}
  defp keycode(name), do: Map.fetch(@key_names, name)

  @doc "The SDL keycode of a named key (`:up`, `:enter`, `:escape`...)."
  def key(name), do: Map.fetch!(@key_names, Atom.to_string(name))

  @doc "Whether Shift is in an SDL modifier set."
  def shift?(mods), do: (mods &&& @kmod_shift) != 0

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
  it. `event` is `{:mouse, kind, button, col, row, mods, clicks}`, with `kind` one
  of `:press`, `:release`, `:motion`, `:wheel`, `button` 0-2 (left, middle,
  right; 3 = none held) or for the wheel 0 (up) and 1 (down), and 0-based
  cell coordinates.

  Mode 9 reports presses alone, 1000 clicks and the wheel, 1002 also motion
  while a button is held, 1003 all motion. The encoding is SGR (mode 1006,
  `CSI < b ; x ; y M` or `m` on release), SGR in pixels (1016, needing
  `cell_pixels`, the size of a cell; each position is that cell's middle),
  urxvt's (1015), or else the original X10 one, with UTF-8 for large
  coordinates under 1005.
  """
  @spec mouse(tuple(), map(), {pos_integer(), pos_integer()} | nil) :: binary() | nil
  def mouse(event, input, cell_pixels \\ nil)

  def mouse({:mouse, kind, button, col, row, mods, _clicks}, input, cell_pixels) do
    if reported?(kind, button, input.mouse) do
      # Mode 9 is the X10 protocol: no modifiers.
      mods = if input.mouse == 9, do: 0, else: mouse_mods(mods)
      code = button_code(kind, button) ||| mods
      encode_mouse(code, kind, col, row, mouse_encoding(input, cell_pixels), cell_pixels)
    end
  end

  defp mouse_encoding(input, cell_pixels) do
    cond do
      Map.get(input, :mouse_pixels, false) and cell_pixels != nil -> :pixels
      input.mouse_sgr -> :sgr
      Map.get(input, :mouse_urxvt, false) -> :urxvt
      Map.get(input, :mouse_utf8, false) -> :utf8
      true -> :x10
    end
  end

  defp reported?(_kind, _button, nil), do: false
  defp reported?(kind, _button, 9), do: kind == :press
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

  defp encode_mouse(code, kind, col, row, :sgr, _cell_pixels) do
    "\e[<#{code};#{col + 1};#{row + 1}" <> if(kind == :release, do: "m", else: "M")
  end

  defp encode_mouse(code, kind, col, row, :pixels, {w, h}) do
    x = col * w + div(w, 2) + 1
    y = row * h + div(h, 2) + 1
    "\e[<#{code};#{x};#{y}" <> if(kind == :release, do: "m", else: "M")
  end

  defp encode_mouse(code, kind, col, row, :urxvt, _cell_pixels) do
    code = if kind == :release, do: 3 ||| (code &&& 0b11100), else: code
    "\e[#{32 + code};#{col + 1};#{row + 1}M"
  end

  # X10, with coordinates as UTF-8 so they can go up to 2015.
  defp encode_mouse(code, kind, col, row, :utf8, _cell_pixels) do
    code = if kind == :release, do: 3 ||| (code &&& 0b11100), else: code

    if col < 1983 and row < 1983,
      do: <<"\e[M", 32 + code, 33 + col::utf8, 33 + row::utf8>>
  end

  # X10: each value is a byte offset by 32, so coordinates stop at 222.
  defp encode_mouse(code, kind, col, row, :x10, _cell_pixels) do
    code = if kind == :release, do: 3 ||| (code &&& 0b11100), else: code

    if col < 223 and row < 223,
      do: <<"\e[M", 32 + code, 33 + col, 33 + row>>
  end
end

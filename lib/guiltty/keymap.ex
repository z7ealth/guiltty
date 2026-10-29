defmodule Guiltty.Keymap do
  @moduledoc """
  Input v0: turns renderer events into the bytes a terminal sends.

  Printable characters arrive as `{:text, utf8}` (SDL's text input, which
  already applied Shift, the keyboard layout and so on) and are sent as is.
  Everything else arrives as `{:key, keycode, mods}` with SDL keycodes:

  | Key             | Bytes            |
  |-----------------|------------------|
  | Enter           | `\\r`             |
  | Backspace       | `0x7F` (DEL)     |
  | Tab             | `\\t`             |
  | Escape          | `0x1B`           |
  | Ctrl+A .. Ctrl+Z| `0x01` .. `0x1A` |

  Ctrl+C is just byte `0x03`: the kernel's line discipline is what turns it
  into SIGINT for the foreground job.
  """

  import Bitwise

  # SDL3 keycodes (SDL_keycode.h). Letters are their lowercase ASCII.
  @sdlk_return 0x0D
  @sdlk_backspace 0x08
  @sdlk_tab 0x09
  @sdlk_escape 0x1B
  @sdlk_kp_enter 0x40000058

  # SDL_Keymod bits
  @kmod_ctrl 0x00C0
  @kmod_alt 0x0300

  @spec to_bytes(Guiltty.Window.Protocol.event()) :: binary() | nil
  def to_bytes({:text, text}), do: text

  def to_bytes({:key, key, mods})
      when key in ?a..?z and (mods &&& @kmod_ctrl) != 0 and (mods &&& @kmod_alt) == 0,
      do: <<key - ?a + 1>>

  def to_bytes({:key, key, _mods}) when key in [@sdlk_return, @sdlk_kp_enter], do: "\r"
  def to_bytes({:key, @sdlk_backspace, _mods}), do: <<0x7F>>
  def to_bytes({:key, @sdlk_tab, _mods}), do: "\t"
  def to_bytes({:key, @sdlk_escape, _mods}), do: <<0x1B>>
  def to_bytes(_event), do: nil
end

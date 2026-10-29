defmodule Guiltty.Parser do
  @moduledoc """
  Parser v0: turns bytes from the shell into screen commands.

  It understands printable ASCII, CR, LF, BS and HT. Escape sequences are
  recognized just enough to be skipped: CSI up to its final byte, OSC (and
  DCS, SOS, PM, APC) up to BEL or ST. Everything else is dropped. Each
  non-ASCII character prints as a single `?`.

  The parser is a value: feed it bytes, get back a new parser and commands.
  State carries over, so a sequence split across two reads still works.

      iex> {_p, cmds} = Guiltty.Parser.feed(Guiltty.Parser.new(), "hi\\e[1mX\\r\\n")
      iex> cmds
      [{:print, "hi"}, {:print, "X"}, :cr, :lf]
  """

  defstruct state: :ground

  @type t :: %__MODULE__{state: state()}
  @type state :: :ground | :escape | :escape_intermediate | :csi | :string | :string_esc
  @type command :: {:print, binary()} | :cr | :lf | :bs | :ht

  @esc 0x1B
  @can 0x18
  @sub 0x1A

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec feed(t(), binary()) :: {t(), [command()]}
  def feed(%__MODULE__{state: state}, bytes) do
    {state, acc} = step(state, bytes, [])
    {%__MODULE__{state: state}, Enum.reverse(acc)}
  end

  defp step(state, <<>>, acc), do: {state, acc}

  # Ground: runs of printable ASCII become one {:print, run}.
  defp step(:ground, bytes, acc) do
    case printable_run(bytes, 0) do
      0 ->
        control(bytes, acc)

      n ->
        <<run::binary-size(^n), rest::binary>> = bytes
        step(:ground, rest, [{:print, run} | acc])
    end
  end

  # ESC seen. The next byte picks the kind of sequence.
  defp step(:escape, <<byte, rest::binary>>, acc) do
    case byte do
      ?[ -> step(:csi, rest, acc)
      # OSC, DCS, SOS, PM, APC: strings that end with BEL or ST (ESC \)
      b when b in [?], ?P, ?X, ?^, ?_] -> step(:string, rest, acc)
      @esc -> step(:escape, rest, acc)
      b when b in [@can, @sub] -> step(:ground, rest, acc)
      # e.g. ESC ( B: intermediates, then a final byte
      b when b in 0x20..0x2F -> step(:escape_intermediate, rest, acc)
      # e.g. ESC 7 (save cursor): a two-byte sequence
      _ -> step(:ground, rest, acc)
    end
  end

  defp step(:escape_intermediate, <<byte, rest::binary>>, acc) do
    if byte in 0x20..0x2F,
      do: step(:escape_intermediate, rest, acc),
      else: step(:ground, rest, acc)
  end

  # CSI: parameters and intermediates until a final byte in 0x40..0x7E.
  defp step(:csi, <<byte, rest::binary>>, acc) do
    cond do
      byte in 0x40..0x7E -> step(:ground, rest, acc)
      byte == @esc -> step(:escape, rest, acc)
      byte in [@can, @sub] -> step(:ground, rest, acc)
      true -> step(:csi, rest, acc)
    end
  end

  defp step(:string, <<byte, rest::binary>>, acc) do
    case byte do
      0x07 -> step(:ground, rest, acc)
      @esc -> step(:string_esc, rest, acc)
      b when b in [@can, @sub] -> step(:ground, rest, acc)
      _ -> step(:string, rest, acc)
    end
  end

  # ESC inside a string: ESC \ is ST and ends it; anything else ends the
  # string and starts a new escape sequence.
  defp step(:string_esc, <<?\\, rest::binary>>, acc), do: step(:ground, rest, acc)
  defp step(:string_esc, bytes, acc), do: step(:escape, bytes, acc)

  defp control(<<byte, rest::binary>>, acc) do
    case byte do
      @esc -> step(:escape, rest, acc)
      ?\r -> step(:ground, rest, [:cr | acc])
      # VT and FF act like LF, as in xterm
      b when b in [?\n, 0x0B, 0x0C] -> step(:ground, rest, [:lf | acc])
      ?\b -> step(:ground, rest, [:bs | acc])
      ?\t -> step(:ground, rest, [:ht | acc])
      # UTF-8 lead byte: one ? per character; continuation bytes are skipped
      b when b >= 0xC0 -> step(:ground, rest, [{:print, "?"} | acc])
      # BEL, DEL, other C0 controls, UTF-8 continuation bytes
      _ -> step(:ground, rest, acc)
    end
  end

  defp printable_run(<<byte, rest::binary>>, n) when byte in 0x20..0x7E,
    do: printable_run(rest, n + 1)

  defp printable_run(_, n), do: n
end

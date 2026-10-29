defmodule Guiltty.Parser do
  @moduledoc """
  Parser v1: Paul Williams' DEC ANSI parser (vt100.net/emu/dec_ansi_parser),
  turning the shell's bytes into commands. It only understands *syntax*;
  `Guiltty.Terminal` decides what each command *means*.

  Commands:

    * `{:print, binary}` - a run of printable ASCII
    * `:cr`, `:lf`, `:bs`, `:ht` - C0 controls (VT and FF count as `:lf`)
    * `{:csi, private, params, intermediates, final}` - e.g. `ESC [ ? 25 l`
      is `{:csi, ??, [25], "", ?l}`. `params` holds integers, `nil` for an
      empty parameter, or a list when the parameter has `:` sub-parameters
      (`38:2::255:0:0` is `[38, 2, nil, 255, 0, 0]`).
    * `{:esc, intermediates, final}` - e.g. `ESC M` is `{:esc, "", ?M}`
    * `{:osc, data}` - an operating system command, e.g. `"0;title"`

  DCS, SOS, PM and APC strings are consumed and dropped. Each non-ASCII
  character still prints as a single `?` until MVP 5 brings UTF-8.

  The parser is a value: state carries over between `feed/2` calls, so a
  sequence split across two reads still works.

      iex> {_p, cmds} = Guiltty.Parser.feed(Guiltty.Parser.new(), "hi\\e[1;31mX\\r\\n")
      iex> cmds
      [{:print, "hi"}, {:csi, nil, [1, 31], "", ?m}, {:print, "X"}, :cr, :lf]
  """

  @max_params 32
  @max_param 65_535
  @max_string 4096

  defstruct state: :ground,
            private: nil,
            intermediates: "",
            # parameters being collected, newest first (see params/1)
            num: nil,
            group: [],
            groups: [],
            seen_param: false,
            # OSC data being collected, as reversed iodata
            string: [],
            string_size: 0

  @type t :: %__MODULE__{}
  @type param :: non_neg_integer() | nil | [non_neg_integer() | nil]
  @type command ::
          {:print, binary()}
          | :cr
          | :lf
          | :bs
          | :ht
          | {:csi, byte() | nil, [param()], binary(), byte()}
          | {:esc, binary(), byte()}
          | {:osc, binary()}

  @esc 0x1B
  @can 0x18
  @sub 0x1A
  @bel 0x07
  @del 0x7F

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec feed(t(), binary()) :: {t(), [command()]}
  def feed(%__MODULE__{} = p, bytes) do
    {p, acc} = step(p.state, bytes, p, [])
    {p, Enum.reverse(acc)}
  end

  # Every state ends here when the input runs out: remember where we were.
  defp step(state, <<>>, p, acc), do: {%{p | state: state}, acc}

  ## Ground: text and C0 controls

  defp step(:ground, bytes, p, acc) do
    case printable_run(bytes, 0) do
      0 ->
        <<byte, rest::binary>> = bytes
        ground_byte(byte, rest, p, acc)

      n ->
        <<run::binary-size(^n), rest::binary>> = bytes
        step(:ground, rest, p, [{:print, run} | acc])
    end
  end

  ## Escape: ESC seen, the next byte picks the kind of sequence

  defp step(:escape, <<byte, rest::binary>>, p, acc) do
    cond do
      c0?(byte) -> anywhere(byte, rest, :escape, p, acc)
      byte in 0x20..0x2F -> step(:escape_intermediate, rest, collect(p, byte), acc)
      byte == ?[ -> step(:csi_entry, rest, p, acc)
      byte == ?] -> step(:osc_string, rest, p, acc)
      byte == ?P -> step(:ignored_string, rest, p, acc)
      byte in [?X, ?^, ?_] -> step(:ignored_string, rest, p, acc)
      byte in 0x30..0x7E -> esc_dispatch(byte, rest, p, acc)
      true -> step(:escape, rest, p, acc)
    end
  end

  defp step(:escape_intermediate, <<byte, rest::binary>>, p, acc) do
    cond do
      c0?(byte) -> anywhere(byte, rest, :escape_intermediate, p, acc)
      byte in 0x20..0x2F -> step(:escape_intermediate, rest, collect(p, byte), acc)
      byte in 0x30..0x7E -> esc_dispatch(byte, rest, p, acc)
      true -> step(:escape_intermediate, rest, p, acc)
    end
  end

  ## CSI: ESC [ private? params intermediates final

  defp step(:csi_entry, <<byte, rest::binary>>, p, acc) do
    cond do
      c0?(byte) -> anywhere(byte, rest, :csi_entry, p, acc)
      byte in 0x3C..0x3F -> step(:csi_param, rest, %{p | private: byte}, acc)
      byte in 0x30..0x3B -> step(:csi_param, rest, param(p, byte), acc)
      byte in 0x20..0x2F -> step(:csi_intermediate, rest, collect(p, byte), acc)
      byte in 0x40..0x7E -> csi_dispatch(byte, rest, p, acc)
      true -> step(:csi_entry, rest, p, acc)
    end
  end

  defp step(:csi_param, <<byte, rest::binary>>, p, acc) do
    cond do
      c0?(byte) -> anywhere(byte, rest, :csi_param, p, acc)
      byte in 0x30..0x3B -> step(:csi_param, rest, param(p, byte), acc)
      # A private marker after parameters is malformed: skip the sequence.
      byte in 0x3C..0x3F -> step(:csi_ignore, rest, p, acc)
      byte in 0x20..0x2F -> step(:csi_intermediate, rest, collect(p, byte), acc)
      byte in 0x40..0x7E -> csi_dispatch(byte, rest, p, acc)
      true -> step(:csi_param, rest, p, acc)
    end
  end

  defp step(:csi_intermediate, <<byte, rest::binary>>, p, acc) do
    cond do
      c0?(byte) -> anywhere(byte, rest, :csi_intermediate, p, acc)
      byte in 0x20..0x2F -> step(:csi_intermediate, rest, collect(p, byte), acc)
      byte in 0x30..0x3F -> step(:csi_ignore, rest, p, acc)
      byte in 0x40..0x7E -> csi_dispatch(byte, rest, p, acc)
      true -> step(:csi_intermediate, rest, p, acc)
    end
  end

  defp step(:csi_ignore, <<byte, rest::binary>>, p, acc) do
    cond do
      c0?(byte) -> anywhere(byte, rest, :csi_ignore, p, acc)
      byte in 0x40..0x7E -> step(:ground, rest, clear(p), acc)
      true -> step(:csi_ignore, rest, p, acc)
    end
  end

  ## Strings: OSC is kept, DCS/SOS/PM/APC are dropped

  defp step(:osc_string, bytes, p, acc) do
    case string_run(bytes, 0) do
      0 ->
        <<byte, rest::binary>> = bytes

        case byte do
          # xterm accepts BEL as well as ST to end an OSC
          @bel -> step(:ground, rest, clear(p), [osc(p) | acc])
          @esc -> step(:osc_esc, rest, p, acc)
          b when b in [@can, @sub] -> step(:ground, rest, clear(p), acc)
          # other C0 controls are ignored inside a string
          _ -> step(:osc_string, rest, p, acc)
        end

      n ->
        <<run::binary-size(^n), rest::binary>> = bytes
        step(:osc_string, rest, put_string(p, run), acc)
    end
  end

  # ESC inside an OSC: ESC \ (ST) ends it. Anything else also ends it, and
  # starts a new escape sequence.
  defp step(:osc_esc, <<?\\, rest::binary>>, p, acc),
    do: step(:ground, rest, clear(p), [osc(p) | acc])

  defp step(:osc_esc, bytes, p, acc), do: step(:escape, bytes, clear(p), [osc(p) | acc])

  defp step(:ignored_string, <<byte, rest::binary>>, p, acc) do
    case byte do
      @esc -> step(:ignored_esc, rest, p, acc)
      b when b in [@can, @sub] -> step(:ground, rest, clear(p), acc)
      _ -> step(:ignored_string, rest, p, acc)
    end
  end

  defp step(:ignored_esc, <<?\\, rest::binary>>, p, acc), do: step(:ground, rest, clear(p), acc)
  defp step(:ignored_esc, bytes, p, acc), do: step(:escape, bytes, clear(p), acc)

  ## Ground bytes that aren't printable ASCII

  defp ground_byte(byte, rest, p, acc) do
    cond do
      c0?(byte) -> anywhere(byte, rest, :ground, p, acc)
      byte == @del -> step(:ground, rest, p, acc)
      # UTF-8 lead byte: one ? per character until MVP 5
      byte >= 0xC0 -> step(:ground, rest, p, [{:print, "?"} | acc])
      # UTF-8 continuation bytes (and 8-bit C1, which UTF-8 terminals ignore)
      true -> step(:ground, rest, p, acc)
    end
  end

  ## C0 controls: the same in every state except strings

  defp c0?(byte), do: byte < 0x20

  defp anywhere(@esc, rest, _state, p, acc), do: step(:escape, rest, clear(p), acc)

  defp anywhere(byte, rest, _state, p, acc) when byte in [@can, @sub],
    do: step(:ground, rest, clear(p), acc)

  defp anywhere(byte, rest, state, p, acc), do: step(state, rest, p, execute(byte, acc))

  defp execute(?\r, acc), do: [:cr | acc]
  defp execute(byte, acc) when byte in [?\n, 0x0B, 0x0C], do: [:lf | acc]
  defp execute(?\b, acc), do: [:bs | acc]
  defp execute(?\t, acc), do: [:ht | acc]
  # BEL, SO, SI and the rest: nothing to do yet
  defp execute(_byte, acc), do: acc

  ## Dispatch

  defp esc_dispatch(final, rest, p, acc) do
    step(:ground, rest, clear(p), [{:esc, p.intermediates, final} | acc])
  end

  defp csi_dispatch(final, rest, p, acc) do
    command = {:csi, p.private, params(p), p.intermediates, final}
    step(:ground, rest, clear(p), [command | acc])
  end

  defp osc(p), do: {:osc, p.string |> Enum.reverse() |> IO.iodata_to_binary()}

  defp clear(p) do
    %{
      p
      | private: nil,
        intermediates: "",
        num: nil,
        group: [],
        groups: [],
        seen_param: false,
        string: [],
        string_size: 0
    }
  end

  defp collect(p, byte), do: %{p | intermediates: p.intermediates <> <<byte>>}

  ## Parameters
  #
  # `;` separates parameters, `:` separates sub-parameters inside one.
  # Digits build `num`; `:` pushes it onto `group`; `;` closes the group.
  # Past @max_params, extra parameters are dropped; values cap at @max_param.

  defp param(p, digit) when digit in ?0..?9 do
    %{p | num: min((p.num || 0) * 10 + digit - ?0, @max_param), seen_param: true}
  end

  defp param(p, ?:), do: %{p | group: [p.num | p.group], num: nil, seen_param: true}

  defp param(p, ?;) do
    groups =
      if length(p.groups) < @max_params,
        do: [close_group([p.num | p.group]) | p.groups],
        else: p.groups

    %{p | groups: groups, group: [], num: nil, seen_param: true}
  end

  defp params(%{seen_param: false}), do: []

  defp params(p) do
    last = close_group([p.num | p.group])
    groups = if length(p.groups) < @max_params, do: [last | p.groups], else: p.groups
    Enum.reverse(groups)
  end

  defp close_group([single]), do: single
  defp close_group(reversed), do: Enum.reverse(reversed)

  defp put_string(%{string_size: size} = p, _run) when size >= @max_string, do: p

  defp put_string(p, run) do
    run = binary_part(run, 0, min(byte_size(run), @max_string - p.string_size))
    %{p | string: [run | p.string], string_size: p.string_size + byte_size(run)}
  end

  ## Runs

  defp printable_run(<<byte, rest::binary>>, n) when byte in 0x20..0x7E,
    do: printable_run(rest, n + 1)

  defp printable_run(_, n), do: n

  # Bytes that are simply part of an OSC string.
  defp string_run(<<byte, rest::binary>>, n) when byte >= 0x20, do: string_run(rest, n + 1)
  defp string_run(_, n), do: n
end

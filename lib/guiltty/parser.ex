defmodule Guiltty.Parser do
  @moduledoc """
  Parser v1: Paul Williams' DEC ANSI parser (vt100.net/emu/dec_ansi_parser),
  turning the shell's bytes into commands. It only understands *syntax*;
  `Guiltty.Terminal` decides what each command *means*.

  Commands:

    * `{:print, binary}` - a run of printable text, valid UTF-8
    * `:cr`, `:lf`, `:bs`, `:ht`, `:shift_out`, `:shift_in`, `:bell` - C0
      controls (VT and FF count as `:lf`)
    * `{:csi, private, params, intermediates, final}` - e.g. `ESC [ ? 25 l`
      is `{:csi, ??, [25], "", ?l}`. `params` holds integers, `nil` for an
      empty parameter, or a list when the parameter has `:` sub-parameters
      (`38:2::255:0:0` is `[38, 2, nil, 255, 0, 0]`).
    * `{:esc, intermediates, final}` - e.g. `ESC M` is `{:esc, "", ?M}`
    * `{:osc, data}` - an operating system command, e.g. `"0;title"`
    * `{:apc, data}` - an application program command, e.g. a Kitty
      graphics command: `ESC _ G a=T;AAAA ESC \\` is `{:apc, "Ga=T;AAAA"}`
    * `{:dcs, data}` - a device control string, e.g. a settings query:
      `ESC P $ q m ESC \\` is `{:dcs, "$qm"}`

  SOS and PM strings are consumed and dropped. A string too long to keep
  is dropped whole, never cut: DCS at 4 KB, OSC at 1 MB (OSC 52 carries the
  clipboard), APC at 64 MB (it carries images, Kitty graphics).

  C1 controls are eight-bit versions of `ESC x`, and in UTF-8 they arrive
  as U+0080 to U+009F: `U+009B` is `ESC [`, as in xterm. They're never text.

  Text is UTF-8. A byte sequence that isn't valid UTF-8 prints as U+FFFD
  (the replacement character, �), the way xterm does.

  The parser is a value: state carries over between `feed/2` calls, so a
  sequence split across two reads still works. That includes a UTF-8
  character cut in half by the read: its first bytes wait in `pending`.

      iex> {_p, cmds} = Guiltty.Parser.feed(Guiltty.Parser.new(), "hi\\e[1;31mX\\r\\n")
      iex> cmds
      [{:print, "hi"}, {:csi, nil, [1, 31], "", ?m}, {:print, "X"}, :cr, :lf]
  """

  alias Guiltty.TextNif

  @max_params 32
  @max_param 65_535
  @max_string 4096
  # OSC 52 carries the clipboard, base64.
  @max_osc 1024 * 1024
  # APC strings carry images (Kitty graphics).
  @max_big_string 64 * 1024 * 1024

  defstruct state: :ground,
            private: nil,
            intermediates: "",
            # parameters being collected, newest first (see params/1)
            num: nil,
            group: [],
            groups: [],
            seen_param: false,
            # OSC, DCS or APC data being collected, as reversed iodata
            string: [],
            string_size: 0,
            # a string grew past its limit: it's dropped
            overflow: false,
            # the start of a UTF-8 character that the last read cut off
            pending: ""

  @type t :: %__MODULE__{}
  @type param :: non_neg_integer() | nil | [non_neg_integer() | nil]
  @type command ::
          {:print, binary()}
          | :cr
          | :lf
          | :bs
          | :ht
          | :shift_out
          | :shift_in
          | {:csi, byte() | nil, [param()], binary(), byte()}
          | {:esc, binary(), byte()}
          | {:osc, binary()}
          | {:apc, binary()}
          | {:dcs, binary()}

  @esc 0x1B
  @can 0x18
  @sub 0x1A
  @bel 0x07
  @replacement "\uFFFD"

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec feed(t(), binary()) :: {t(), [command()]}
  def feed(%__MODULE__{} = p, bytes) do
    {bytes, p} = {p.pending <> bytes, %{p | pending: ""}}
    {p, acc} = step(p.state, bytes, p, [])
    {p, Enum.reverse(acc)}
  end

  # Every state ends here when the input runs out: remember where we were.
  defp step(state, <<>>, p, acc), do: {%{p | state: state}, acc}

  ## Ground: text and C0 controls

  # Text is most of what programs print. Where a run of it ends is found
  # in C (Guiltty.TextNif.text_run/1), in one call instead of one step per
  # byte (book chapter 22). A control byte is handled here without the
  # call: between escape sequences, a call that answers 0 costs more than
  # it saves.
  defp step(:ground, <<byte, rest::binary>>, p, acc) when byte < 0x20 or byte == 0x7F,
    do: ground_byte(byte, rest, p, acc)

  # A C1 control is the ESC sequence it stands for. text_run stops before one.
  defp step(:ground, <<0xC2, c1, rest::binary>>, p, acc) when c1 in 0x80..0x9F,
    do: step(:escape, <<c1 - 0x40, rest::binary>>, clear(p), acc)

  defp step(:ground, bytes, p, acc) do
    n = TextNif.text_run(bytes)
    <<run::binary-size(^n), rest::binary>> = bytes
    text(run, rest, p, acc)
  end

  ## Escape: ESC seen, the next byte picks the kind of sequence

  defp step(:escape, <<byte, rest::binary>>, p, acc) do
    cond do
      c0?(byte) -> anywhere(byte, rest, :escape, p, acc)
      byte in 0x20..0x2F -> step(:escape_intermediate, rest, collect(p, byte), acc)
      byte == ?[ -> step(:csi_entry, rest, p, acc)
      byte == ?] -> step(:osc_string, rest, p, acc)
      byte == ?_ -> step(:apc_string, rest, p, acc)
      byte == ?P -> step(:dcs_string, rest, p, acc)
      byte in [?X, ?^] -> step(:ignored_string, rest, p, acc)
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

  ## APC: ESC _ string ST (Kitty graphics)

  defp step(:apc_string, bytes, p, acc), do: apc_string(bytes, p, acc)

  # ESC inside an APC: ESC \ (ST) ends it. Anything else drops it and
  # starts a new escape sequence.
  defp step(:apc_esc, <<?\\, rest::binary>>, p, acc),
    do: step(:ground, rest, clear(p), apc_command(p, acc))

  defp step(:apc_esc, bytes, p, acc), do: step(:escape, bytes, clear(p), acc)

  ## Strings: OSC and DCS are kept, SOS and PM are dropped

  defp step(:osc_string, bytes, p, acc),
    do: kept_string(bytes, :osc_string, :osc_esc, @max_osc, &osc_command/2, p, acc)

  # ESC inside an OSC: ESC \\ (ST) ends it. Anything else also ends it, and
  # starts a new escape sequence.
  defp step(:osc_esc, <<?\\, rest::binary>>, p, acc),
    do: step(:ground, rest, clear(p), osc_command(p, acc))

  defp step(:osc_esc, bytes, p, acc), do: step(:escape, bytes, clear(p), osc_command(p, acc))

  defp step(:dcs_string, bytes, p, acc),
    do: kept_string(bytes, :dcs_string, :dcs_esc, @max_string, &dcs_command/2, p, acc)

  # ESC inside a DCS: ESC \\ (ST) ends it. Anything else drops it.
  defp step(:dcs_esc, <<?\\, rest::binary>>, p, acc),
    do: step(:ground, rest, clear(p), dcs_command(p, acc))

  defp step(:dcs_esc, bytes, p, acc), do: step(:escape, bytes, clear(p), acc)

  # ST as a C1 control, U+009C. Its first byte may end this read.
  defp step(:ignored_string, <<0xC2, 0x9C, rest::binary>>, p, acc),
    do: step(:ground, rest, clear(p), acc)

  defp step(:ignored_string, <<0xC2>>, p, acc),
    do: {%{p | state: :ignored_string, pending: <<0xC2>>}, acc}

  defp step(:ignored_string, <<byte, rest::binary>>, p, acc) do
    case byte do
      @esc -> step(:ignored_esc, rest, p, acc)
      b when b in [@can, @sub] -> step(:ground, rest, clear(p), acc)
      _ -> step(:ignored_string, rest, p, acc)
    end
  end

  defp step(:ignored_esc, <<?\\, rest::binary>>, p, acc), do: step(:ground, rest, clear(p), acc)
  defp step(:ignored_esc, bytes, p, acc), do: step(:escape, bytes, clear(p), acc)

  # The body of an OSC or DCS. BEL ends an OSC, as in xterm; other C0 controls
  # inside a string are ignored.
  defp kept_string(<<0xC2, 0x9C, rest::binary>>, _state, _esc, _max, finish, p, acc),
    do: step(:ground, rest, clear(p), finish.(p, acc))

  defp kept_string(<<0xC2>>, state, _esc, _max, _finish, p, acc),
    do: {%{p | state: state, pending: <<0xC2>>}, acc}

  defp kept_string(<<0xC2, rest::binary>>, state, _esc, max, _finish, p, acc),
    do: step(state, rest, put_string(p, <<0xC2>>, max), acc)

  defp kept_string(bytes, state, esc, max, finish, p, acc) do
    case string_run(bytes, 0) do
      0 ->
        <<byte, rest::binary>> = bytes

        case byte do
          @bel when state == :osc_string -> step(:ground, rest, clear(p), finish.(p, acc))
          @esc -> step(esc, rest, p, acc)
          b when b in [@can, @sub] -> step(:ground, rest, clear(p), acc)
          _ -> step(state, rest, p, acc)
        end

      n ->
        <<run::binary-size(^n), rest::binary>> = bytes
        step(state, rest, put_string(p, run, max), acc)
    end
  end

  # An APC body: everything up to ESC (or CAN/SUB, which cancel it), found
  # with one :binary.match instead of a step per byte. An image is
  # megabytes of base64.
  defp apc_string(bytes, p, acc) do
    case :binary.match(bytes, [<<@esc>>, <<@can>>, <<@sub>>, <<0xC2, 0x9C>>]) do
      :nomatch ->
        # the rest comes in the next read (with ST's first byte, if it's cut)
        {run, pending} = split_trailing_c2(bytes)
        {%{put_big_string(p, run) | state: :apc_string, pending: pending}, acc}

      {at, 2} ->
        <<run::binary-size(^at), _st::binary-size(2), rest::binary>> = bytes
        p = put_big_string(p, run)
        step(:ground, rest, clear(p), apc_command(p, acc))

      {at, 1} ->
        <<run::binary-size(^at), byte, rest::binary>> = bytes
        p = put_big_string(p, run)

        if byte == @esc,
          do: step(:apc_esc, rest, p, acc),
          else: step(:ground, rest, clear(p), acc)
    end
  end

  defp split_trailing_c2(bytes) do
    n = byte_size(bytes) - 1

    case bytes do
      <<run::binary-size(^n), 0xC2>> -> {run, <<0xC2>>}
      _ -> {bytes, ""}
    end
  end

  defp put_big_string(p, ""), do: p
  defp put_big_string(%{overflow: true} = p, _run), do: p

  defp put_big_string(p, run) do
    size = p.string_size + byte_size(run)

    if size > @max_big_string,
      do: %{p | overflow: true, string: [], string_size: 0},
      else: %{p | string: [run | p.string], string_size: size}
  end

  defp apc_command(%{overflow: true}, acc), do: acc

  defp apc_command(p, acc),
    do: [{:apc, p.string |> Enum.reverse() |> IO.iodata_to_binary()} | acc]

  ## Text

  # A run of bytes that may be text. Valid UTF-8 prints; an invalid byte
  # prints as U+FFFD and decoding goes on after it. An incomplete character
  # at the very end of the input waits for the next read; anywhere else
  # (a control byte cut it short) it's invalid too.
  #
  defp text(run, rest, p, acc) do
    case :unicode.characters_to_binary(run) do
      valid when is_binary(valid) ->
        step(:ground, rest, p, [{:print, valid} | acc])

      {:incomplete, valid, partial} when rest == "" ->
        {%{p | state: :ground, pending: partial}, print(valid, acc)}

      {:incomplete, valid, _partial} ->
        step(:ground, rest, p, [{:print, @replacement} | print(valid, acc)])

      {:error, valid, <<_bad, after_bad::binary>>} ->
        text_after(after_bad, rest, p, [{:print, @replacement} | print(valid, acc)])
    end
  end

  defp text_after("", rest, p, acc), do: step(:ground, rest, p, acc)
  defp text_after(run, rest, p, acc), do: text(run, rest, p, acc)

  defp print("", acc), do: acc
  defp print(text, acc), do: [{:print, text} | acc]

  ## Ground bytes that aren't text

  defp ground_byte(byte, rest, p, acc) do
    cond do
      c0?(byte) -> anywhere(byte, rest, :ground, p, acc)
      # DEL
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
  # SO and SI pick the G1 or G0 character set (see Guiltty.Terminal)
  defp execute(0x0E, acc), do: [:shift_out | acc]
  defp execute(0x0F, acc), do: [:shift_in | acc]
  defp execute(@bel, acc), do: [:bell | acc]
  # the rest: nothing to do
  defp execute(_byte, acc), do: acc

  ## Dispatch

  defp esc_dispatch(final, rest, p, acc) do
    step(:ground, rest, clear(p), [{:esc, p.intermediates, final} | acc])
  end

  defp csi_dispatch(final, rest, p, acc) do
    command = {:csi, p.private, params(p), p.intermediates, final}
    step(:ground, rest, clear(p), [command | acc])
  end

  defp osc_command(%{overflow: true}, acc), do: acc
  defp osc_command(p, acc), do: [{:osc, string(p)} | acc]

  defp dcs_command(%{overflow: true}, acc), do: acc
  defp dcs_command(p, acc), do: [{:dcs, string(p)} | acc]

  defp string(p), do: p.string |> Enum.reverse() |> IO.iodata_to_binary()

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
        string_size: 0,
        overflow: false
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

  defp put_string(%{overflow: true} = p, _run, _max), do: p

  defp put_string(p, run, max) do
    size = p.string_size + byte_size(run)

    if size > max,
      do: %{p | overflow: true, string: [], string_size: 0},
      else: %{p | string: [run | p.string], string_size: size}
  end

  ## Runs

  # Bytes that are simply part of a string; 0xC2 may start ST (U+009C).
  defp string_run(<<byte, rest::binary>>, n) when byte >= 0x20 and byte != 0xC2,
    do: string_run(rest, n + 1)

  defp string_run(_, n), do: n
end

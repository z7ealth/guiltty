defmodule Guiltty.Terminal do
  @moduledoc """
  What the parser's commands *mean*: applies them to a `Guiltty.Grid`.

  | Sequence                 | Name        | Effect                                  |
  |--------------------------|-------------|-----------------------------------------|
  | CR LF BS HT, SO SI       | C0          | the usual; SO/SI pick G1/G0             |
  | `CSI n A/B/C/D`          | CUU/CUD/CUF/CUB | cursor up/down/forward/back         |
  | `CSI n E/F`              | CNL/CPL     | down/up n lines, to column 1            |
  | `CSI n G`, `` CSI n ` `` | CHA/HPA     | to column n                             |
  | `CSI n a`, `CSI n e`     | HPR/VPR     | right / down n                          |
  | `CSI n d`                | VPA         | to row n                                |
  | `CSI r;c H/f`            | CUP/HVP     | to row r, column c (1-based)            |
  | `CSI n J`, `CSI n K`     | ED, EL      | erase in display, in line               |
  | `CSI n X`                | ECH         | erase n characters                      |
  | `CSI n @`, `CSI n P`     | ICH, DCH    | insert / delete n characters            |
  | `CSI n L`, `CSI n M`     | IL, DL      | insert / delete n lines                 |
  | `CSI n S`, `CSI n T`     | SU, SD      | scroll the region up / down             |
  | `CSI t;b r`              | DECSTBM     | set the scroll region                   |
  | `CSI n b`                | REP         | repeat the last character n times       |
  | `CSI s`, `CSI u`         | SCOSC/SCORC | save / restore the cursor               |
  | `CSI 4 h/l`              | IRM         | insert mode                             |
  | `CSI ... m`              | SGR         | colors and attributes (`Guiltty.SGR`)   |
  | `CSI c`, `CSI > c`       | DA1, DA2    | answer: what kind of terminal this is   |
  | `CSI 5 n`, `CSI 6 n`     | DSR, CPR    | answer: status OK, cursor position      |
  | `CSI ! p`                | DECSTR      | soft reset                              |
  | `CSI n SP q`             | DECSCUSR    | cursor shape: 1-2 block, 3-4 underline, 5-6 bar (odd blinks); 0 the user's |
  | `CSI ? n h/l`            | DECSET/RST  | private modes, see `dec_mode/3`         |
  | `ESC 7`, `ESC 8`         | DECSC/DECRC | save / restore the cursor               |
  | `ESC D`, `ESC E`, `ESC M`| IND/NEL/RI  | index, next line, reverse index         |
  | `ESC =`, `ESC >`         | DECKPAM/PNM | keypad: application / numeric           |
  | `ESC ( 0`, `ESC ( B`     | SCS         | G0 = line drawing / ASCII (`)` for G1)  |
  | `ESC # 8`                | DECALN      | fill the screen with E                  |
  | `ESC c`                  | RIS         | full reset                              |
  | `OSC 0;t`, `OSC 2;t`     |             | window title                            |

  Anything else is ignored.
  """

  alias Guiltty.{Grid, Parser, SGR}

  # What we answer to "what are you?": a VT220 (62) with ANSI color (22).
  # A low DA2 version keeps programs like vim from assuming a recent xterm
  # and asking for features guiltty doesn't have yet.
  @da1 "\e[?62;22c"
  @da2 "\e[>1;10;0c"
  @max_title 256

  @spec apply(Grid.t(), [Parser.command()]) :: Grid.t()
  def apply(grid, commands), do: Enum.reduce(commands, grid, &command/2)

  defp command({:print, text}, grid), do: Grid.print(grid, text)
  defp command(:cr, grid), do: Grid.carriage_return(grid)
  defp command(:lf, grid), do: Grid.index(grid)
  defp command(:bs, grid), do: Grid.backspace(grid)
  defp command(:ht, grid), do: Grid.tab(grid)
  defp command(:shift_out, grid), do: Grid.shift(grid, 1)
  defp command(:shift_in, grid), do: Grid.shift(grid, 0)

  defp command({:csi, nil, params, "", final}, grid), do: csi(final, params, grid)

  defp command({:csi, ??, params, "", final}, grid) when final in [?h, ?l],
    do: dec_modes(params, final == ?h, grid)

  defp command({:csi, ?>, params, "", ?c}, grid) when params in [[], [0]],
    do: Grid.respond(grid, @da2)

  defp command({:csi, nil, [], "!", ?p}, grid), do: Grid.soft_reset(grid)

  defp command({:csi, nil, params, " ", ?q}, grid),
    do: Grid.set_cursor_style(grid, cursor_style(value(params, 0, 0)))

  defp command({:esc, "", ?7}, grid), do: Grid.save_cursor(grid)
  defp command({:esc, "", ?8}, grid), do: Grid.restore_cursor(grid)
  defp command({:esc, "", ?D}, grid), do: Grid.index(grid)
  defp command({:esc, "", ?E}, grid), do: grid |> Grid.carriage_return() |> Grid.index()
  defp command({:esc, "", ?M}, grid), do: Grid.reverse_index(grid)
  defp command({:esc, "", ?=}, grid), do: Grid.set_input(grid, :keypad, :application)
  defp command({:esc, "", ?>}, grid), do: Grid.set_input(grid, :keypad, :numeric)
  defp command({:esc, "", ?c}, grid), do: Grid.reset(grid)
  defp command({:esc, "#", ?8}, grid), do: Grid.fill_with_e(grid)
  defp command({:esc, "(", final}, grid), do: Grid.designate(grid, :g0, charset(final))
  defp command({:esc, ")", final}, grid), do: Grid.designate(grid, :g1, charset(final))

  defp command({:osc, data}, grid), do: osc(data, grid)

  defp command(_ignored, grid), do: grid

  ## CSI

  defp csi(?A, params, grid), do: Grid.move_by(grid, -count(params), 0)
  defp csi(?B, params, grid), do: Grid.move_by(grid, count(params), 0)
  defp csi(?e, params, grid), do: Grid.move_by(grid, count(params), 0)
  defp csi(?C, params, grid), do: Grid.move_by(grid, 0, count(params))
  defp csi(?a, params, grid), do: Grid.move_by(grid, 0, count(params))
  defp csi(?D, params, grid), do: Grid.move_by(grid, 0, -count(params))
  defp csi(?E, params, grid), do: grid |> Grid.move_by(count(params), 0) |> Grid.carriage_return()

  defp csi(?F, params, grid),
    do: grid |> Grid.move_by(-count(params), 0) |> Grid.carriage_return()

  defp csi(final, params, grid) when final in [?G, ?`],
    do: %{grid | col: min(count(params) - 1, grid.cols - 1)}

  defp csi(?d, params, grid), do: Grid.move_to(grid, count(params) - 1, grid.col)

  defp csi(final, params, grid) when final in [?H, ?f] do
    Grid.move_to(grid, count(params, 0) - 1, count(params, 1) - 1)
  end

  defp csi(?J, params, grid), do: Grid.erase_display(grid, value(params, 0, 0))
  defp csi(?K, params, grid), do: Grid.erase_line(grid, value(params, 0, 0))
  defp csi(?X, params, grid), do: Grid.erase_chars(grid, count(params))
  defp csi(?@, params, grid), do: Grid.insert_chars(grid, count(params))
  defp csi(?P, params, grid), do: Grid.delete_chars(grid, count(params))
  defp csi(?L, params, grid), do: Grid.insert_lines(grid, count(params))
  defp csi(?M, params, grid), do: Grid.delete_lines(grid, count(params))
  defp csi(?S, params, grid), do: Grid.scroll_up(grid, count(params))
  # CSI T with several parameters is an old mouse-tracking reply, not SD.
  defp csi(?T, params, grid) when length(params) <= 1, do: Grid.scroll_down(grid, count(params))
  defp csi(?b, params, grid), do: Grid.repeat(grid, count(params))
  defp csi(?m, params, grid), do: SGR.apply(grid, params)

  defp csi(?r, params, grid) do
    Grid.set_region(grid, count(params, 0) - 1, value(params, 1, grid.rows) - 1)
  end

  defp csi(?s, [], grid), do: Grid.save_cursor(grid)
  defp csi(?u, [], grid), do: Grid.restore_cursor(grid)

  defp csi(final, params, grid) when final in [?h, ?l] do
    if 4 in params, do: Grid.set_mode(grid, :insert, final == ?h), else: grid
  end

  defp csi(?c, params, grid) when params in [[], [0]], do: Grid.respond(grid, @da1)
  defp csi(?n, [5], grid), do: Grid.respond(grid, "\e[0n")

  defp csi(?n, [6], grid) do
    {_row, col} = Grid.cursor(grid)
    Grid.respond(grid, "\e[#{Grid.report_row(grid) + 1};#{col + 1}R")
  end

  defp csi(_final, _params, grid), do: grid

  ## DEC private modes (CSI ? n h / l)

  defp dec_modes(params, on?, grid), do: Enum.reduce(params, grid, &dec_mode(&1, on?, &2))

  defp dec_mode(1, on?, grid),
    do: Grid.set_input(grid, :cursor_keys, if(on?, do: :application, else: :normal))

  defp dec_mode(6, on?, grid), do: Grid.set_origin(grid, on?)
  defp dec_mode(7, on?, grid), do: Grid.set_mode(grid, :autowrap, on?)
  defp dec_mode(25, on?, grid), do: Grid.set_cursor_visible(grid, on?)

  # Alternate screen. 47: just switch. 1047: clear it on the way in.
  # 1049: also save the cursor before, and restore it after.
  defp dec_mode(47, true, grid), do: Grid.enter_alt(grid, clear: false)
  defp dec_mode(47, false, grid), do: Grid.leave_alt(grid)
  defp dec_mode(1047, true, grid), do: Grid.enter_alt(grid, clear: true)
  defp dec_mode(1047, false, grid), do: Grid.leave_alt(grid)
  defp dec_mode(1048, true, grid), do: Grid.save_cursor(grid)
  defp dec_mode(1048, false, grid), do: Grid.restore_cursor(grid)
  defp dec_mode(1049, true, grid), do: grid |> Grid.save_cursor() |> Grid.enter_alt(clear: true)
  defp dec_mode(1049, false, grid), do: grid |> Grid.leave_alt() |> Grid.restore_cursor()

  # Mouse reporting: which events (1000 clicks, 1002 drags, 1003 all
  # motion), and how they're encoded (1006: SGR, the only one we send).
  defp dec_mode(mode, true, grid) when mode in [1000, 1002, 1003],
    do: Grid.set_input(grid, :mouse, mode)

  defp dec_mode(mode, false, grid) when mode in [1000, 1002, 1003],
    do: Grid.set_input(grid, :mouse, nil)

  defp dec_mode(1006, on?, grid), do: Grid.set_input(grid, :mouse_sgr, on?)
  defp dec_mode(2004, on?, grid), do: Grid.set_input(grid, :bracketed_paste, on?)
  defp dec_mode(_mode, _on?, grid), do: grid

  ## Cursor shapes

  defp cursor_style(n) when n in 1..6,
    do: {Enum.at([:block, :underline, :bar], div(n - 1, 2)), rem(n, 2) == 1}

  defp cursor_style(_n), do: nil

  ## Character sets

  defp charset(?0), do: :dec_graphics
  defp charset(_), do: :ascii

  ## OSC

  # 0 sets the icon name and the title, 2 just the title.
  defp osc(<<code, ?;, title::binary>>, grid) when code in [?0, ?2] do
    Grid.set_title(grid, clean_title(title))
  end

  defp osc(_data, grid), do: grid

  # Titles come from programs, maybe from a server at the other end of
  # ssh. Keep them short, valid UTF-8, and free of:
  # - control characters, C0 and C1;
  # - bidi controls, which reorder how the text around them reads (the
  #   "Trojan Source" trick);
  # - guiltty's own tab markers (🔒 locked, 📡 broadcast, 🏠 local, ⚠
  #   lost), so a title can't pretend a tab is locked or in the group.
  @title_junk ~r/[\x{00}-\x{1f}\x{7f}-\x{9f}\x{200e}\x{200f}\x{202a}-\x{202e}\x{2066}-\x{2069}\x{1f512}\x{1f4e1}\x{1f3e0}\x{26a0}\x{fe0f}]/u

  @doc false
  def clean_title(title) do
    title
    |> String.replace_invalid()
    |> String.replace(@title_junk, "")
    |> String.trim()
    |> truncate_utf8(@max_title)
  end

  defp truncate_utf8(text, max) when byte_size(text) <= max, do: text

  defp truncate_utf8(text, max),
    do: text |> binary_part(0, max) |> String.chunk(:valid) |> List.first("")

  ## Parameters

  # A parameter that may carry sub-parameters (`38:5:1`): use the first.
  defp value(params, i, default) do
    case Enum.at(params, i) do
      nil -> default
      [first | _] -> first || default
      n -> n
    end
  end

  # Counts and positions: missing or 0 means 1.
  defp count(params, i \\ 0), do: max(value(params, i, 1), 1)
end

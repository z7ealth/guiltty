defmodule Guiltty.Terminal do
  @moduledoc """
  What the parser's commands *mean*: applies them to a `Guiltty.Grid`.

  | Sequence                 | Name        | Effect                                  |
  |--------------------------|-------------|-----------------------------------------|
  | CR LF BS HT, SO SI       | C0          | the usual; SO/SI pick G1/G0             |
  | `CSI n A/B/C/D`          | CUU/CUD/CUF/CUB | cursor up/down/forward/back         |
  | `CSI n E/F`              | CNL/CPL     | down/up n lines, to column 1            |
  | `CSI n G`, `` CSI n ` `` | CHA/HPA     | to column n                             |
  | `HT`, `CSI n I`, `CSI n Z` | HT/CHT/CBT | n tab stops forward or back            |
  | `ESC H`, `CSI n g`       | HTS, TBC    | set a tab stop, clear one or all        |
  | `CSI n a`, `CSI n e`     | HPR/VPR     | right / down n                          |
  | `CSI n d`                | VPA         | to row n                                |
  | `CSI r;c H/f`            | CUP/HVP     | to row r, column c (1-based)            |
  | `CSI n J`, `CSI n K`     | ED, EL      | erase in display, in line               |
  | `CSI n X`                | ECH         | erase n characters                      |
  | `CSI n @`, `CSI n P`     | ICH, DCH    | insert / delete n characters            |
  | `CSI n L`, `CSI n M`     | IL, DL      | insert / delete n lines                 |
  | `CSI n S`, `CSI n T`     | SU, SD      | scroll the region up / down             |
  | `CSI t;b r`              | DECSTBM     | set the scroll region                   |
  | `CSI l;r s`              | DECSLRM     | set the margins (with mode 69 on)       |
  | `CSI n SP @`, `CSI n SP A` | SL, SR    | move the columns inside the margins     |
  | `CSI n ' }`, `CSI n ' ~` | DECIC/DECDC | insert or delete columns                |
  | `ESC 6`, `ESC 9`         | DECBI/DECFI | back or forward; at the margin, shift   |
  | `CSI ... $ x z { v r t`  | DECFRA ...  | fill, erase, copy and restyle rectangles |
  | `CSI n " q`, `CSI ? n J/K` | DECSCA ... | protect cells; erase all but those     |
  | `CSI # {`, `CSI # }`     | XTPUSHSGR   | save and restore the pen                |
  | `CSI 22 t`, `CSI 23 t`   | XTWINOPS    | save and restore the title              |
  | `CSI n b`                | REP         | repeat the last character n times       |
  | `CSI s`, `CSI u`         | SCOSC/SCORC | save / restore the cursor               |
  | `CSI 4 h/l`              | IRM         | insert mode                             |
  | `CSI ... m`              | SGR         | colors and attributes (`Guiltty.SGR`)   |
  | `CSI c`, `CSI > c`, `CSI = c` | DA1-3  | answer: what kind of terminal this is   |
  | `CSI 5 n`, `CSI 6 n`, `CSI ? n n` | DSR, CPR | answer: status, cursor position, ...  |
  | `CSI n $ p`, `CSI ? n $ p` | DECRQM    | answer: whether a mode is on            |
  | `CSI n x`                | DECREQTPARM | answer: a VT100's serial line settings  |
  | `DCS $ q ... ST`         | DECRQSS     | answer: a setting's current value       |
  | `DCS + q ... ST`         | XTGETTCAP   | answer: a terminfo capability           |
  | `CSI ... * y`            | DECRQCRA    | answer: a checksum of part of the screen (if `screen_reports` is on) |
  | `CSI ? u`, `> u`, `< u`, `= u` | Kitty keyboard | ask about, push, pop and set flags |
  | `CSI 14/16/18 t`         | XTWINOPS    | answer: text area, cell size (pixels), grid size |
  | `CSI > q`                | XTVERSION   | answer: guiltty and its version         |
  | `APC G ... ST`           | Kitty graphics | images, see `Guiltty.Graphics`       |
  | `CSI ! p`                | DECSTR      | soft reset                              |
  | `CSI n SP q`             | DECSCUSR    | cursor shape: 1-2 block, 3-4 underline, 5-6 bar (odd blinks); 0 the user's |
  | `CSI ? n h/l`            | DECSET/RST  | private modes, see `dec_mode/3`         |
  | `ESC 7`, `ESC 8`         | DECSC/DECRC | save / restore the cursor               |
  | `ESC D`, `ESC E`, `ESC M`| IND/NEL/RI  | index, next line, reverse index         |
  | `ESC =`, `ESC >`         | DECKPAM/PNM | keypad: application / numeric           |
  | `ESC ( 0`, `ESC ( B`, `ESC ( A` | SCS  | G0 = line drawing / ASCII / UK (`)`, `*`, `+` for G1 to G3) |
  | `ESC - A`, `ESC . A`, `ESC / A` |      | G1 to G3 = ISO Latin-1's upper half     |
  | `ESC n`, `ESC o`, `ESC N`, `ESC O` | LS2, LS3, SS2, SS3 | use G2 or G3, or just for the next character |
  | `ESC # 8`                | DECALN      | fill the screen with E                  |
  | `ESC c`                  | RIS         | full reset                              |
  | `OSC 0;t`, `OSC 1;t`, `OSC 2;t` |      | title and icon name                     |
  | `OSC 4;n;c`, `OSC 104;n` |             | set or ask for a palette color; reset   |
  | `OSC 10`, `11`, `12`     |             | set or ask for fg, bg, cursor; `110` ... reset |
  | `OSC 7;uri`              |             | the program's working directory         |
  | `OSC 8;;uri`             |             | hyperlink; empty `uri` ends it          |
  | `OSC 52;c;base64`        |             | put text on the clipboard (never read)  |
  | `OSC 133;A`              |             | a prompt starts here                    |

  Anything else is ignored. Some sequences are refused on purpose, because a
  program may not be who you think it is (a server at the other end of ssh, or
  a file you `cat`): reading the title (`CSI 21 t`) and the clipboard (`OSC 52;c;?`),
  whose answers arrive as if you typed them; resizing or moving the window
  (the rest of XTWINOPS); and, unless `screen_reports` is on, DECRQCRA.
  """

  import Bitwise

  alias Guiltty.{Graphics, Grid, Parser, SGR, Theme}

  # What we answer to "what are you?": a VT520 (65) with ANSI color (22) and
  # rectangular editing (28), selective erase (6) and horizontal scrolling
  # (21). DA2's first number is the same answer, in xterm's numbering (64). A
  # low version keeps programs like vim from assuming guiltty is a recent
  # xterm in every other way.
  @da1 "\e[?65;6;21;22;28c"
  @version Mix.Project.config()[:version]
  @da2 "\e[>64;10;0c"
  @da3 "\eP!|00000000\e\\"
  @max_title 256
  @max_uri 2048

  @spec apply(Grid.t(), [Parser.command()]) :: Grid.t()
  def apply(grid, commands) do
    commands |> run(Grid.forget_prompt_rows(grid)) |> Grid.prune_graphics()
  end

  # Lines of plain text (print, CR, LF), however many come in a row, go to
  # the grid together: it can lay them all down and scroll once.
  defp run([{:print, _}, :cr, :lf | _] = commands, grid) do
    {texts, rest} = take_lines(commands, [])
    run(rest, Grid.print_lines(grid, texts))
  end

  defp run([command | rest], grid), do: run(rest, command(command, grid))
  defp run([], grid), do: grid

  defp take_lines([{:print, text}, :cr, :lf | rest], texts), do: take_lines(rest, [text | texts])
  defp take_lines(rest, texts), do: {Enum.reverse(texts), rest}

  defp command({:print, text}, grid), do: Grid.print(grid, text)
  defp command(:cr, grid), do: Grid.carriage_return(grid)

  defp command(:lf, %{input: %{newline_mode: true}} = grid),
    do: grid |> Grid.index() |> Grid.carriage_return()

  defp command(:lf, grid), do: Grid.index(grid)
  defp command(:bs, grid), do: Grid.backspace(grid)
  defp command(:ht, grid), do: Grid.tab(grid)
  defp command(:shift_out, grid), do: Grid.shift(grid, 1)
  defp command(:shift_in, grid), do: Grid.shift(grid, 0)
  defp command(:bell, grid), do: Grid.ring(grid)

  defp command({:csi, nil, params, "", final}, grid), do: csi(final, params, grid)

  defp command({:csi, ??, params, "", final}, grid) when final in [?h, ?l],
    do: dec_modes(params, final == ?h, grid)

  # XTSAVE, XTRESTORE: remember DEC modes, and put them back.
  defp command({:csi, ??, params, "", ?s}, grid) do
    saved =
      Enum.reduce(params, grid.saved_modes, fn mode, saved ->
        case dec_state(grid, mode) do
          state when is_boolean(state) -> Map.put(saved, mode, state)
          _ -> saved
        end
      end)

    %{grid | saved_modes: saved}
  end

  defp command({:csi, ??, params, "", ?r}, grid) do
    Enum.reduce(params, grid, fn mode, grid ->
      case grid.saved_modes do
        %{^mode => state} -> dec_mode(mode, state, grid)
        _ -> grid
      end
    end)
  end

  defp command({:csi, ??, params, "", ?J}, grid),
    do: Grid.selective_erase_display(grid, value(params, 0, 0))

  defp command({:csi, ??, params, "", ?K}, grid),
    do: Grid.selective_erase_line(grid, value(params, 0, 0))

  defp command({:csi, ??, params, "", ?n}, grid),
    do: dec_status(value(params, 0, 0), params, grid)

  defp command({:csi, ??, params, "$", ?p}, grid) do
    mode = value(params, 0, 0)
    Grid.respond(grid, "\e[?#{mode};#{mode_answer(dec_state(grid, mode))}$y")
  end

  defp command({:csi, nil, params, "$", ?p}, grid) do
    mode = value(params, 0, 0)
    Grid.respond(grid, "\e[#{mode};#{mode_answer(ansi_state(grid, mode))}$y")
  end

  # The Kitty keyboard protocol's flags: ask, push, pop, set.
  defp command({:csi, ??, [], "", ?u}, grid),
    do: Grid.respond(grid, "\e[?#{grid.input.kitty}u")

  defp command({:csi, ?>, params, "", ?u}, grid), do: Grid.push_kitty(grid, value(params, 0, 0))
  defp command({:csi, ?<, params, "", ?u}, grid), do: Grid.pop_kitty(grid, count(params))

  defp command({:csi, ?=, params, "", ?u}, grid),
    do: Grid.set_kitty(grid, value(params, 0, 0), value(params, 1, 1))

  defp command({:csi, ?>, params, "", ?c}, grid) when params in [[], [0]],
    do: Grid.respond(grid, @da2)

  defp command({:csi, ?=, params, "", ?c}, grid) when params in [[], [0]],
    do: Grid.respond(grid, @da3)

  defp command({:csi, nil, [], "!", ?p}, grid), do: Grid.soft_reset(grid)

  defp command({:csi, nil, params, " ", ?q}, grid),
    do: Grid.set_cursor_style(grid, cursor_style(value(params, 0, 0)))

  defp command({:csi, nil, params, " ", ?@}, grid), do: Grid.shift_columns(grid, -count(params))
  defp command({:csi, nil, params, " ", ?A}, grid), do: Grid.shift_columns(grid, count(params))
  defp command({:csi, nil, params, "'", ?}}, grid), do: Grid.insert_columns(grid, count(params))
  defp command({:csi, nil, params, "'", ?~}, grid), do: Grid.delete_columns(grid, count(params))

  defp command({:csi, nil, params, "\"", ?q}, grid),
    do: Grid.set_protected(grid, value(params, 0, 0) == 1)

  # DECSCL picks a VT level; guiltty stays what it is, and remembers.
  defp command({:csi, nil, params, "\"", ?p}, grid) do
    level = value(params, 0, 0)

    if level in 61..65,
      do: %{Grid.soft_reset(grid) | conformance: {level, value(params, 1, 0)}},
      else: grid
  end

  defp command({:csi, nil, _params, "#", ?\{}, grid), do: Grid.push_sgr(grid)
  defp command({:csi, nil, _params, "#", ?\}}, grid), do: Grid.pop_sgr(grid)

  defp command({:csi, nil, [ch | params], "$", ?x}, grid) do
    code = value([ch], 0, 0)

    case rect(grid, params) do
      rect when rect != nil and (code in 32..126 or code in 160..255) ->
        Grid.fill_rect(grid, code, rect)

      _ ->
        grid
    end
  end

  defp command({:csi, nil, params, "$", ?z}, grid), do: on_rect(grid, params, &Grid.erase_rect/2)

  defp command({:csi, nil, params, "$", ?\{}, grid),
    do: on_rect(grid, params, &Grid.selective_erase_rect/2)

  defp command({:csi, nil, params, "$", ?v}, grid) do
    {source, rest} = Enum.split(params, 4)

    with {_, _, _, _} = rect <- rect(grid, source),
         # the source's page, then the destination's row, column and page
         [_page | to] <- pad(rest, 4) do
      {to_row, to_col} = from_origin(grid, count(to, 0) - 1, count(to, 1) - 1)
      Grid.copy_rect(grid, rect, {to_row, to_col})
    else
      _ -> grid
    end
  end

  defp command({:csi, nil, params, "$", ?r}, grid) do
    {area, attrs} = Enum.split(params, 4)
    change_rect(grid, area, &rect_attrs_after(&1, attrs, :set))
  end

  defp command({:csi, nil, params, "$", ?t}, grid) do
    {area, attrs} = Enum.split(params, 4)
    change_rect(grid, area, &rect_attrs_after(&1, attrs, :toggle))
  end

  # DECSACE: how DECCARA and DECRARA read their rectangle.
  defp command({:csi, nil, params, "*", ?x}, grid),
    do: %{grid | sace_rect: value(params, 0, 0) == 2}

  defp command({:csi, nil, params, "*", ?y}, %{screen_reports: true} = grid) do
    id = value(params, 0, 0)
    {_page, area} = Enum.split(params, 2)

    case rect(grid, area) do
      nil -> Grid.respond(grid, "\eP#{id}!~0000\e\\")
      rect -> Grid.respond(grid, "\eP#{id}!~#{hex4(Grid.checksum_rect(grid, rect))}\e\\")
    end
  end

  defp command({:esc, "", ?H}, grid), do: Grid.set_tab_stop(grid)
  defp command({:esc, "", ?6}, grid), do: Grid.back_index(grid)
  defp command({:esc, "", ?9}, grid), do: Grid.forward_index(grid)
  defp command({:esc, "", ?n}, grid), do: Grid.shift(grid, 2)
  defp command({:esc, "", ?o}, grid), do: Grid.shift(grid, 3)
  defp command({:esc, "", ?N}, grid), do: Grid.single_shift(grid, :g2)
  defp command({:esc, "", ?O}, grid), do: Grid.single_shift(grid, :g3)

  defp command({:esc, "", ?7}, grid), do: Grid.save_cursor(grid)
  defp command({:esc, "", ?8}, grid), do: Grid.restore_cursor(grid)
  defp command({:esc, "", ?D}, grid), do: Grid.index(grid)
  # In this order: whether a line feed scrolls depends on where the cursor is.
  defp command({:esc, "", ?E}, grid), do: grid |> Grid.index() |> Grid.carriage_return()
  # DECID: the old way to ask for DA1.
  defp command({:esc, "", ?Z}, grid), do: Grid.respond(grid, @da1)
  defp command({:esc, "", ?M}, grid), do: Grid.reverse_index(grid)
  defp command({:esc, "", ?=}, grid), do: Grid.set_input(grid, :keypad, :application)
  defp command({:esc, "", ?>}, grid), do: Grid.set_input(grid, :keypad, :numeric)
  defp command({:esc, "", ?c}, grid), do: Grid.reset(grid)
  defp command({:esc, "#", ?8}, grid), do: Grid.fill_with_e(grid)
  defp command({:esc, "(", final}, grid), do: Grid.designate(grid, :g0, charset(final))
  defp command({:esc, ")", final}, grid), do: Grid.designate(grid, :g1, charset(final))
  defp command({:esc, "*", final}, grid), do: Grid.designate(grid, :g2, charset(final))
  defp command({:esc, "+", final}, grid), do: Grid.designate(grid, :g3, charset(final))
  # The 96-character sets, for G1 to G3. A is ISO Latin-1's upper half.
  defp command({:esc, "-", final}, grid), do: Grid.designate(grid, :g1, charset96(final))
  defp command({:esc, ".", final}, grid), do: Grid.designate(grid, :g2, charset96(final))
  defp command({:esc, "/", final}, grid), do: Grid.designate(grid, :g3, charset96(final))

  defp command({:osc, data}, grid), do: osc(data, grid)
  defp command({:dcs, data}, grid), do: dcs(data, grid)

  # Images: Kitty graphics (APC G). See Guiltty.Graphics.
  defp command({:apc, "G" <> body}, grid), do: Graphics.kitty(grid, body)

  # XTVERSION: our name and version, as DCS > | text ST.
  defp command({:csi, ?>, params, "", ?q}, grid) when params in [[], [0]],
    do: Grid.respond(grid, "\eP>|guiltty #{@version}\e\\")

  defp command(_ignored, grid), do: grid

  ## CSI

  defp csi(?A, params, grid), do: Grid.move_by(grid, -count(params), 0)
  defp csi(?B, params, grid), do: Grid.move_by(grid, count(params), 0)
  defp csi(?e, params, grid), do: Grid.move_by(grid, count(params), 0)
  defp csi(?C, params, grid), do: Grid.move_by(grid, 0, count(params))
  defp csi(?a, params, grid), do: Grid.move_by(grid, 0, count(params))
  defp csi(?D, params, grid), do: Grid.move_back(grid, count(params))
  defp csi(?E, params, grid), do: grid |> Grid.move_by(count(params), 0) |> Grid.carriage_return()

  defp csi(?F, params, grid),
    do: grid |> Grid.move_by(-count(params), 0) |> Grid.carriage_return()

  defp csi(final, params, grid) when final in [?G, ?`], do: Grid.move_col(grid, count(params) - 1)
  defp csi(?d, params, grid), do: Grid.move_row(grid, count(params) - 1)
  defp csi(?I, params, grid), do: Grid.tab(grid, count(params))
  defp csi(?Z, params, grid), do: Grid.back_tab(grid, count(params))
  defp csi(?g, params, grid), do: Grid.clear_tab_stop(grid, value(params, 0, 0))

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

  # DECREQTPARM: the VT100's serial line settings, which mean nothing here but
  # are what a VT100 program expects: no parity, 8 bits, 19200 baud.
  defp csi(?x, params, grid) when params in [[], [0], [1]] do
    kind = if params == [1], do: 3, else: 2
    Grid.respond(grid, "\e[#{kind};1;1;128;128;1;0x")
  end

  # With left and right margins on, CSI s can't also save the cursor.
  defp csi(?s, params, %{lrmm: true} = grid),
    do: Grid.set_margins(grid, count(params, 0) - 1, value(params, 1, grid.cols) - 1)

  defp csi(?s, [], grid), do: Grid.save_cursor(grid)
  defp csi(?u, [], grid), do: Grid.restore_cursor(grid)

  defp csi(final, params, grid) when final in [?h, ?l] do
    Enum.reduce(params, grid, fn
      4, grid -> Grid.set_mode(grid, :insert, final == ?h)
      20, grid -> Grid.set_input(grid, :newline_mode, final == ?h)
      _other, grid -> grid
    end)
  end

  defp csi(?c, params, grid) when params in [[], [0]], do: Grid.respond(grid, @da1)
  defp csi(?n, [5], grid), do: Grid.respond(grid, "\e[0n")

  defp csi(?n, [6], grid),
    do: Grid.respond(grid, "\e[#{Grid.report_row(grid) + 1};#{Grid.report_col(grid) + 1}R")

  # The title stack, which terminfo's smcup and rmcup use around full-screen
  # programs. 0 is the title and icon name, 1 the icon name, 2 the title.
  defp csi(?t, [22 | rest], grid), do: Grid.push_title(grid, title_part(rest))
  defp csi(?t, [23 | rest], grid), do: Grid.pop_title(grid, title_part(rest))

  # Reading the title back can type a program's words at the shell: refused,
  # unless asked for like DECRQCRA.
  defp csi(?t, [20], %{screen_reports: true} = grid),
    do: Grid.respond(grid, "\e]L#{grid.icon_name}\e\\")

  defp csi(?t, [21], %{screen_reports: true} = grid),
    do: Grid.respond(grid, "\e]l#{grid.title}\e\\")

  # XTWINOPS reports, for programs that draw images: the text area (14)
  # and one cell (16) in pixels, as height;width, and the grid in cells
  # (18). The pixel ones only once the renderer has told us the cell size:
  # no answer makes a program fall back, a made-up one makes it draw
  # images the wrong size.
  defp csi(?t, [14], %{cell_pixels: {w, h}} = grid),
    do: Grid.respond(grid, "\e[4;#{h * grid.rows};#{w * grid.cols}t")

  defp csi(?t, [16], %{cell_pixels: {w, h}} = grid), do: Grid.respond(grid, "\e[6;#{h};#{w}t")
  defp csi(?t, [18], grid), do: Grid.respond(grid, "\e[8;#{grid.rows};#{grid.cols}t")

  defp csi(_final, _params, grid), do: grid

  ## DEC private modes (CSI ? n h / l)

  defp dec_modes(params, on?, grid), do: Enum.reduce(params, grid, &dec_mode(&1, on?, &2))

  defp dec_mode(1, on?, grid),
    do: Grid.set_input(grid, :cursor_keys, if(on?, do: :application, else: :normal))

  defp dec_mode(5, on?, grid), do: Grid.set_reverse_video(grid, on?)
  defp dec_mode(6, on?, grid), do: Grid.set_origin(grid, on?)
  defp dec_mode(7, on?, grid), do: Grid.set_mode(grid, :autowrap, on?)
  defp dec_mode(12, on?, grid), do: Grid.set_cursor_blink(grid, on?)
  defp dec_mode(25, on?, grid), do: Grid.set_cursor_visible(grid, on?)
  defp dec_mode(45, on?, grid), do: Grid.set_mode(grid, :reverse_wrap, on?)
  defp dec_mode(1045, on?, grid), do: Grid.set_mode(grid, :reverse_wrap_all, on?)

  defp dec_mode(66, on?, grid),
    do: Grid.set_input(grid, :keypad, if(on?, do: :application, else: :numeric))

  defp dec_mode(67, on?, grid), do: Grid.set_input(grid, :backarrow_bs, on?)
  defp dec_mode(69, on?, grid), do: Grid.set_margin_mode(grid, on?)
  defp dec_mode(1004, on?, grid), do: Grid.set_input(grid, :focus_events, on?)
  defp dec_mode(1005, on?, grid), do: Grid.set_input(grid, :mouse_utf8, on?)
  defp dec_mode(1007, on?, grid), do: Grid.set_input(grid, :alternate_scroll, on?)
  defp dec_mode(1015, on?, grid), do: Grid.set_input(grid, :mouse_urxvt, on?)
  defp dec_mode(1016, on?, grid), do: Grid.set_input(grid, :mouse_pixels, on?)
  defp dec_mode(2026, on?, grid), do: Grid.set_synchronized(grid, on?)

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

  # Mouse reporting: which events (9 presses, 1000 clicks, 1002 drags, 1003
  # all motion), and how they're encoded (1005, 1006, 1015, 1016).
  defp dec_mode(mode, true, grid) when mode in [9, 1000, 1002, 1003],
    do: Grid.set_input(grid, :mouse, mode)

  defp dec_mode(mode, false, grid) when mode in [9, 1000, 1002, 1003],
    do: Grid.set_input(grid, :mouse, nil)

  defp dec_mode(1006, on?, grid), do: Grid.set_input(grid, :mouse_sgr, on?)
  defp dec_mode(2004, on?, grid), do: Grid.set_input(grid, :bracketed_paste, on?)
  defp dec_mode(_mode, _on?, grid), do: grid

  # What DECRQM and XTSAVE say about a mode: on, off, :always (2027, clusters
  # are how guiltty always works), or nil for one guiltty doesn't have.
  defp dec_state(grid, 1), do: grid.input.cursor_keys == :application
  defp dec_state(grid, 5), do: grid.reverse_video
  defp dec_state(grid, 6), do: grid.origin
  defp dec_state(grid, 7), do: grid.autowrap
  defp dec_state(grid, 9), do: grid.input.mouse == 9
  defp dec_state(grid, 12), do: grid.cursor_blink == true
  defp dec_state(grid, 25), do: grid.cursor_visible
  defp dec_state(grid, 45), do: grid.reverse_wrap
  defp dec_state(grid, 1045), do: grid.reverse_wrap_all
  defp dec_state(grid, mode) when mode in [47, 1047, 1049], do: grid.alt?
  defp dec_state(grid, 66), do: grid.input.keypad == :application
  defp dec_state(grid, 67), do: grid.input.backarrow_bs
  defp dec_state(grid, 69), do: grid.lrmm
  defp dec_state(grid, mode) when mode in [1000, 1002, 1003], do: grid.input.mouse == mode
  defp dec_state(grid, 1004), do: grid.input.focus_events
  defp dec_state(grid, 1005), do: grid.input.mouse_utf8
  defp dec_state(grid, 1006), do: grid.input.mouse_sgr
  defp dec_state(grid, 1007), do: grid.input.alternate_scroll
  defp dec_state(grid, 1015), do: grid.input.mouse_urxvt
  defp dec_state(grid, 1016), do: grid.input.mouse_pixels
  defp dec_state(grid, 2004), do: grid.input.bracketed_paste
  defp dec_state(grid, 2026), do: grid.synchronized
  defp dec_state(_grid, 2027), do: :always
  # Real modes, on DEC's list, that guiltty doesn't offer: 132 columns (a
  # program can't resize the window), smooth scroll, printing, and the like.
  defp dec_state(_grid, mode) when mode in [3, 4, 18, 19, 35, 42, 60], do: :never
  defp dec_state(_grid, _mode), do: nil

  defp ansi_state(grid, 4), do: grid.insert
  defp ansi_state(grid, 20), do: grid.input.newline_mode
  # The rest of ECMA-48's modes: keyboard locks, editing boundaries...
  defp ansi_state(_grid, mode) when mode in [1, 2, 5, 7, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19],
    do: :never

  defp ansi_state(_grid, _mode), do: nil

  # DECRPM: 0 not recognized, 1 set, 2 reset, 3 permanently set, 4 permanently reset.
  defp mode_answer(true), do: 1
  defp mode_answer(false), do: 2
  defp mode_answer(:always), do: 3
  defp mode_answer(:never), do: 4
  defp mode_answer(nil), do: 0

  defp title_part([1 | _]), do: :icon
  defp title_part([2 | _]), do: :title
  defp title_part(_both), do: :both

  ## DEC status reports (CSI ? n n)

  # Where the cursor is: line, column, page (always 1).
  defp dec_status(6, _params, grid),
    do: Grid.respond(grid, "\e[?#{Grid.report_row(grid) + 1};#{Grid.report_col(grid) + 1};1R")

  # No printer, user-defined keys locked, a keyboard (US, ready), no locator.
  defp dec_status(15, _params, grid), do: Grid.respond(grid, "\e[?13n")
  defp dec_status(25, _params, grid), do: Grid.respond(grid, "\e[?21n")
  defp dec_status(26, _params, grid), do: Grid.respond(grid, "\e[?27;1;0;0n")
  defp dec_status(53, _params, grid), do: Grid.respond(grid, "\e[?50n")
  defp dec_status(55, _params, grid), do: Grid.respond(grid, "\e[?50n")
  defp dec_status(56, _params, grid), do: Grid.respond(grid, "\e[?57;0n")
  # Macro space, and its checksum: there are no macros.
  defp dec_status(62, _params, grid), do: Grid.respond(grid, "\e[0*{")

  defp dec_status(63, params, grid),
    do: Grid.respond(grid, "\eP#{value(params, 1, 0)}!~0000\e\\")

  # Data integrity: no errors. Multiple sessions: not supported.
  defp dec_status(75, _params, grid), do: Grid.respond(grid, "\e[?70n")
  defp dec_status(85, _params, grid), do: Grid.respond(grid, "\e[?83n")
  defp dec_status(_other, _params, grid), do: grid

  ## Rectangles

  # Top, left, bottom, right, as the sequences give them (1-based, and from
  # the corner of the region and margins in origin mode), or nil when they
  # don't make a rectangle.
  defp rect(grid, params) do
    {top, left} = from_origin(grid, count(params, 0) - 1, count(params, 1) - 1)

    {bottom, right} =
      from_origin(
        grid,
        value(params, 2, last_row(grid)) - 1,
        value(params, 3, last_col(grid)) - 1
      )

    bottom = min(bottom, grid.rows - 1)
    right = min(right, grid.cols - 1)
    if top <= bottom and left <= right, do: {top, left, bottom, right}
  end

  defp last_row(%{origin: true} = grid), do: grid.bottom - grid.top + 1
  defp last_row(grid), do: grid.rows
  defp last_col(%{origin: true} = grid), do: grid.right - grid.left + 1
  defp last_col(grid), do: grid.cols

  defp from_origin(%{origin: true} = grid, row, col),
    do: {min(row + grid.top, grid.bottom), min(col + grid.left, grid.right)}

  defp from_origin(grid, row, col), do: {min(row, grid.rows - 1), min(col, grid.cols - 1)}

  defp on_rect(grid, params, fun) do
    case rect(grid, params) do
      nil -> grid
      rect -> fun.(grid, rect)
    end
  end

  defp pad(list, n), do: list ++ List.duplicate(nil, max(n - length(list), 0))

  defp change_rect(grid, area, fun) do
    case rect(grid, area) do
      nil -> grid
      rect -> Grid.change_rect_attrs(grid, rect, fun, stream: not grid.sace_rect)
    end
  end

  # Attributes per cell, for DECCARA (:set) and DECRARA (:toggle).
  defp rect_attrs_after(attrs, params, mode) do
    params = if params == [], do: [0], else: params

    Enum.reduce(params, attrs, fn param, attrs ->
      case {mode, value([param], 0, 0)} do
        {:set, 0} -> attrs &&& bnot(rect_attrs())
        {:set, 22} -> attrs &&& bnot(Grid.attr(:bold))
        {:set, 24} -> attrs &&& bnot(Grid.attr(:underline))
        {:set, 25} -> attrs &&& bnot(Grid.attr(:blink))
        {:set, 27} -> attrs &&& bnot(Grid.attr(:inverse))
        {:set, n} -> attrs ||| rect_attr(n)
        {:toggle, 0} -> bxor(attrs, rect_attrs())
        {:toggle, n} -> bxor(attrs, rect_attr(n))
      end
    end)
  end

  defp rect_attr(1), do: Grid.attr(:bold)
  defp rect_attr(4), do: Grid.attr(:underline)
  defp rect_attr(5), do: Grid.attr(:blink)
  defp rect_attr(7), do: Grid.attr(:inverse)
  defp rect_attr(_other), do: 0

  defp rect_attrs,
    do: Grid.attr(:bold) ||| Grid.attr(:underline) ||| Grid.attr(:blink) ||| Grid.attr(:inverse)

  defp hex4(n), do: n |> Integer.to_string(16) |> String.pad_leading(4, "0")

  ## DCS

  defp dcs("$q" <> setting, grid) do
    case setting_value(setting, grid) do
      nil -> Grid.respond(grid, "\eP0$r\e\\")
      value -> Grid.respond(grid, "\eP1$r#{value}\e\\")
    end
  end

  defp dcs("+q" <> names, grid) do
    names |> String.split(";") |> Enum.reduce(grid, &answer_capability/2)
  end

  defp dcs(_other, grid), do: grid

  # DECRQSS: a setting's value, written as the sequence that would set it.
  defp setting_value("m", grid), do: "#{SGR.report(grid)}m"
  defp setting_value("r", grid), do: "#{grid.top + 1};#{grid.bottom + 1}r"
  defp setting_value("s", grid), do: "#{grid.left + 1};#{grid.right + 1}s"
  defp setting_value("t", grid), do: "#{grid.rows}t"
  defp setting_value("$|", grid), do: "#{grid.cols}$|"
  defp setting_value("*|", grid), do: "#{grid.rows}*|"

  defp setting_value("\"p", %{conformance: {level, bits}}),
    do: ~s(#{level};#{if bits == 1, do: 1, else: 0}"p)

  defp setting_value("\"q", grid) do
    protected? = (grid.attrs &&& Grid.attr(:protected)) != 0
    ~s(#{if protected?, do: 1, else: 0}"q)
  end

  defp setting_value(" q", grid), do: "#{cursor_number(grid.cursor_style)} q"
  defp setting_value("*x", grid), do: "#{if grid.sace_rect, do: 2, else: 0}*x"
  # Settings with one possible value here: the status line (none).
  defp setting_value(setting, _grid) when setting in ["$}", "$~"], do: "0" <> setting
  defp setting_value(_setting, _grid), do: nil

  defp cursor_number(nil), do: 0

  defp cursor_number({shape, blink}) do
    base = Map.fetch!(%{block: 1, underline: 3, bar: 5}, shape)
    if blink, do: base, else: base + 1
  end

  # XTGETTCAP: terminfo capabilities that programs ask a terminal directly,
  # because terminfo on a remote host may not know it. Names and values are
  # in hex.
  @capabilities %{
    "TN" => "xterm-256color",
    "name" => "xterm-256color",
    "Co" => "256",
    "colors" => "256",
    "RGB" => "8/8/8"
  }

  # What isn't hex gets no answer: an answer arrives at the program as if you
  # typed it, so it must never repeat what the program sent, unless it's only
  # hex digits, which do nothing.
  defp answer_capability(hex, grid) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, name} ->
        case @capabilities do
          %{^name => value} ->
            Grid.respond(grid, "\eP1+r#{hex}=#{Base.encode16(value)}\e\\")

          _ ->
            Grid.respond(grid, "\eP0+r#{hex}\e\\")
        end

      :error ->
        grid
    end
  end

  ## Cursor shapes

  defp cursor_style(n) when n in 1..6,
    do: {Enum.at([:block, :underline, :bar], div(n - 1, 2)), rem(n, 2) == 1}

  defp cursor_style(_n), do: nil

  ## Character sets

  defp charset(?0), do: :dec_graphics
  defp charset(?A), do: :uk
  defp charset(_), do: :ascii

  defp charset96(?A), do: :latin1
  defp charset96(_), do: :ascii

  ## OSC

  # 0 sets the icon name and the title, 1 the icon name, 2 just the title.
  defp osc("0;" <> title, grid) do
    title = clean_title(title)
    grid |> Grid.set_title(title) |> Grid.set_icon_name(title)
  end

  defp osc("1;" <> name, grid), do: Grid.set_icon_name(grid, clean_title(name))
  defp osc("2;" <> title, grid), do: Grid.set_title(grid, clean_title(title))
  defp osc("4;" <> rest, grid), do: palette_colors(String.split(rest, ";"), grid)

  defp osc("7;" <> uri, grid) do
    if byte_size(uri) <= @max_uri and String.printable?(uri),
      do: Grid.set_cwd_uri(grid, uri),
      else: grid
  end

  # OSC 8 ; params ; uri. The parameters (an id, for one link across several
  # lines) aren't needed: every cell knows its own link.
  defp osc("8;" <> rest, grid) do
    case String.split(rest, ";", parts: 2) do
      [_params, ""] -> Grid.set_link(grid, nil)
      [_params, uri] -> set_link(uri, grid)
      _ -> grid
    end
  end

  defp osc("10;" <> rest, grid), do: dynamic_colors(String.split(rest, ";"), 10, grid)
  defp osc("11;" <> rest, grid), do: dynamic_colors(String.split(rest, ";"), 11, grid)
  defp osc("12;" <> rest, grid), do: dynamic_colors(String.split(rest, ";"), 12, grid)
  defp osc("52;" <> rest, grid), do: clipboard(String.split(rest, ";", parts: 2), grid)
  defp osc("104", grid), do: Grid.reset_palette(grid)

  defp osc("104;", grid), do: Grid.reset_palette(grid)

  defp osc("104;" <> rest, grid) do
    rest
    |> String.split(";")
    |> Enum.reduce(grid, fn index, grid ->
      case Integer.parse(index) do
        {n, ""} when n in 0..255 -> Grid.set_palette(grid, n, nil)
        _ -> grid
      end
    end)
  end

  defp osc("110" <> _, grid), do: Grid.set_dynamic_color(grid, :fg_color, nil)
  defp osc("111" <> _, grid), do: Grid.set_dynamic_color(grid, :bg_color, nil)
  defp osc("112" <> _, grid), do: Grid.set_dynamic_color(grid, :cursor_color, nil)

  # A prompt starts here. C, D and the rest say where a command's output is;
  # guiltty only needs the prompts.
  defp osc("133;A" <> _, grid), do: Grid.mark_prompt(grid)
  defp osc(_data, grid), do: grid

  defp set_link(uri, grid) do
    if byte_size(uri) <= @max_uri and String.printable?(uri),
      do: Grid.set_link(grid, uri),
      else: grid
  end

  # OSC 52 ; targets ; base64. Writing only: `?` asks to read the clipboard,
  # and the answer would arrive at the program as if you typed it, so any
  # program (or a file you cat) could read what you copied.
  defp clipboard([_targets, "?"], grid), do: grid

  defp clipboard([targets, data], grid) do
    with {:ok, text} <- Base.decode64(data, padding: false),
         true <- text != "" and String.valid?(text) and not String.contains?(text, <<0>>) do
      Grid.set_clipboard(grid, clipboard_target(targets), text)
    else
      _ -> grid
    end
  end

  defp clipboard(_other, grid), do: grid

  defp clipboard_target(targets) do
    if String.contains?(targets, "p") and not String.contains?(targets, "c"),
      do: :primary,
      else: :clipboard
  end

  ## Colors (OSC 4, 10, 11, 12)

  defp palette_colors([index, spec | rest], grid) do
    grid =
      case {Integer.parse(index), spec} do
        {{n, ""}, "?"} when n in 0..255 ->
          report_color(grid, "4;#{n}", palette_color(grid, n))

        {{n, ""}, _} when n in 0..255 ->
          case parse_color(spec) do
            nil -> grid
            color -> Grid.set_palette(grid, n, color)
          end

        _ ->
          grid
      end

    palette_colors(rest, grid)
  end

  defp palette_colors(_rest, grid), do: grid

  # OSC 10 ; a ; b sets 10 to a and 11 to b: each value goes to the next code.
  defp dynamic_colors([], _code, grid), do: grid
  defp dynamic_colors(_specs, code, grid) when code > 12, do: grid

  defp dynamic_colors([spec | rest], code, grid) do
    field = %{10 => :fg_color, 11 => :bg_color, 12 => :cursor_color}[code]

    grid =
      case spec do
        "?" ->
          report_color(grid, "#{code}", dynamic_color(grid, field))

        _ ->
          case parse_color(spec) do
            nil -> grid
            color -> Grid.set_dynamic_color(grid, field, color)
          end
      end

    dynamic_colors(rest, code + 1, grid)
  end

  defp palette_color(grid, n) do
    case grid.palette do
      %{^n => color} -> color
      _ -> grid |> theme() |> Theme.palette() |> Enum.at(n)
    end
  end

  defp dynamic_color(grid, :fg_color), do: grid.fg_color || theme(grid).fg
  defp dynamic_color(grid, :bg_color), do: grid.bg_color || theme(grid).bg
  defp dynamic_color(grid, :cursor_color), do: grid.cursor_color || theme(grid).cursor

  defp theme(%{theme: nil}), do: Theme.default()
  defp theme(%{theme: theme}), do: theme

  # Each component in 16 bits, the way xterm answers: 0xAB is abab.
  defp report_color(grid, code, {r, g, b}) do
    hex = fn c ->
      c |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")
    end

    double = fn c -> hex.(c) <> hex.(c) end
    Grid.respond(grid, "\e]#{code};rgb:#{double.(r)}/#{double.(g)}/#{double.(b)}\e\\")
  end

  # What XParseColor reads, of its many forms: rgb:R/G/B with 1 to 4 hex
  # digits each, scaled to 8 bits; rgbi:R/G/B with 0.0 to 1.0 each; and #RGB
  # with 1 to 4 digits per component, whose digits are the top bits (#f is
  # f0, not ff). CIE color spaces and color names aren't read.
  @doc false
  def parse_color("rgb:" <> rest) do
    case String.split(rest, "/") do
      [_, _, _] = parts -> components(parts)
      _ -> nil
    end
  end

  def parse_color("rgbi:" <> rest) do
    values =
      rest
      |> String.split("/")
      |> Enum.map(fn part ->
        case Float.parse(part) do
          {f, ""} when f >= 0.0 and f <= 1.0 -> round(f * 255)
          _ -> nil
        end
      end)

    if length(values) == 3 and nil not in values, do: List.to_tuple(values)
  end

  def parse_color("#" <> hex) when byte_size(hex) in [3, 6, 9, 12] do
    size = div(byte_size(hex), 3)
    values = for <<part::binary-size(^size) <- hex>>, do: top_bits(part)
    if nil in values, do: nil, else: List.to_tuple(values)
  end

  def parse_color(_spec), do: nil

  defp top_bits(part) do
    case Integer.parse(part, 16) do
      {n, ""} when byte_size(part) == 1 -> n * 16
      {n, ""} -> n >>> (4 * byte_size(part) - 8)
      _ -> nil
    end
  end

  defp components(parts) do
    values =
      Enum.map(parts, fn part ->
        case Integer.parse(part, 16) do
          {n, ""} when byte_size(part) in 1..4 -> div(n * 255, 16 ** byte_size(part) - 1)
          _ -> nil
        end
      end)

    if nil in values, do: nil, else: List.to_tuple(values)
  end

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

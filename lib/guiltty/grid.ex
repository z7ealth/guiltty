defmodule Guiltty.Grid do
  @moduledoc """
  The screen as data: rows of cells, a cursor, the current *pen* (the style
  new text is written with), and the terminal's modes.

  A cell is 14 bytes, and a row is one binary of `cols` cells:

      <<glyph::32, attrs::16, fg::32, bg::32>>

  `glyph` is what the cell shows:

    * a Unicode codepoint (up to `0x10FFFF`), for the usual case;
    * a *cluster id* (`0x110000` and up) when it takes several codepoints
      (`e` + a combining accent, a flag, an emoji with a skin tone). The
      grid's `clusters` map holds the text of each id;
    * `0` in the right half of a wide character.

  `attrs` holds bit flags (see the `@bold` etc. below). A wide character
  (CJK, most emoji) takes two cells: the first has the `wide` flag, the
  second, the *spacer*, has `spacer`. A color is one of:

    * `0` - the default foreground or background
    * `0x01_0000NN` - palette index `NN` (0-255)
    * `0x02_RRGGBB` - a 24-bit color

  The renderer understands the same layout, so a row goes to it unchanged.

  ## Scrollback

  On the main screen, rows that scroll off the top are kept in
  `scrollback`, up to `scrollback_max` of them. Every row that ever
  scrolled off has a number, counting from 0: the scrollback holds rows
  `scrollback_first` to `history - 1`, and the screen's row `r` is row
  `history + r`. Those numbers don't change as more output arrives, so a
  selection or a search match stays on the text it was on.

  New rows collect in `recent` (a list, newest first). Every 256 rows are
  sealed into a *block*: one binary with the rows end to end, trailing
  blank cells cut off, and a tuple of where each row starts. A row costs a
  list prepend; a block, one allocation. Any row is found in O(1).

  There are two screens. The *main* one is where the shell runs; full-screen
  programs switch to the *alternate* one and back, which brings the shell's
  screen back as it was. `lines` is always the active screen; the other one
  waits in `other_lines`.

  The cursor column may equal `cols`: the last cell was just written and the
  wrap is pending. The next printable character wraps; a CR or a cursor
  movement doesn't. xterm behaves the same way.
  """

  import Bitwise

  alias Guiltty.Graphics
  alias Guiltty.{TextNif, Unicode}

  @cell_size 14
  @block 256

  # attrs bits
  @bold 0x01
  @dim 0x02
  @italic 0x04
  @underline 0x08
  @blink 0x10
  @inverse 0x20
  @hidden 0x40
  @strike 0x80
  @wide 0x100
  @spacer 0x200
  # Set by Guiltty.View on what it shows, never stored in the grid.
  @match 0x400
  @current_match 0x800
  @overline 0x1000
  # DECSCA: selective erase leaves this cell alone.
  @protected 0x2000
  # On a row's last cell: the text goes on in the next row (it wrapped).
  # This is how a resize knows what to join again (reflow).
  @wrapped 0x4000
  # Part of a hyperlink (OSC 8): `links` says where it goes.
  @link 0x8000
  # The pen's bits that SGR doesn't touch: SGR 0 keeps them.
  @sticky @protected ||| @link

  @default_color 0

  @first_cluster 0x110000
  # Past this many distinct clusters, new ones show their first codepoint.
  @max_clusters 65_536
  # The renderer keeps cluster text up to this many bytes.
  @max_cluster_bytes 64
  @blank <<?\s::32, 0::16, @default_color::32, @default_color::32>>
  # A row of blank cells as wide as the widest grid (the renderer's limit),
  # made once: scrollback rows are trimmed by comparing against it.
  @blanks :binary.copy(@blank, 4096)

  # Modes that change what the keyboard and mouse send; Window reads them.
  @input_modes %{
    cursor_keys: :normal,
    keypad: :numeric,
    bracketed_paste: false,
    mouse: nil,
    mouse_sgr: false,
    mouse_utf8: false,
    mouse_urxvt: false,
    mouse_pixels: false,
    # LNM: Enter sends CR LF, and a line feed also returns the carriage
    newline_mode: false,
    focus_events: false,
    # the wheel on the alternate screen sends arrow keys (mode 1007); on
    # by default, unlike xterm's, so less and man scroll
    alternate_scroll: true,
    # DECBKM: Backspace sends BS instead of DEL
    backarrow_bs: false,
    # Kitty keyboard protocol flags (see Guiltty.Keymap)
    kitty: 0
  }

  # How many saved SGR pens and titles a program may stack up (xterm's limit).
  @max_stack 10
  @max_links 2048
  @max_marks 1024
  # Only this many of the newest rows of scrollback are rewrapped on a
  # resize: the rest keep their shape, cut or padded when shown.
  @reflow_rows 100_000

  defstruct [
    :cols,
    :rows,
    :lines,
    other_lines: nil,
    alt?: false,
    row: 0,
    col: 0,
    attrs: 0,
    fg: @default_color,
    bg: @default_color,
    # scroll region, 0-based and inclusive
    top: 0,
    bottom: nil,
    # left and right margins (DECSLRM), 0-based and inclusive; margins? says
    # they're narrower than the screen, which sends text the slow way
    left: 0,
    right: nil,
    margins?: false,
    # DECLRMM: CSI s sets the margins instead of saving the cursor
    lrmm: false,
    # {row, col}: the last cell inside the margins was just written, so the
    # next character wraps. Without margins, col == cols says the same.
    pending_at: nil,
    # tab stops, sorted: nil is every 8 columns, as a new terminal has
    tabs: nil,
    reverse_wrap: false,
    reverse_wrap_all: false,
    # DECSCNM: the whole screen in reverse video (Guiltty.View draws it)
    reverse_video: false,
    # mode 12: the program's say on blinking, or nil for the cursor's own
    cursor_blink: nil,
    cursor_visible: true,
    # set by the program (DECSCUSR): {:block | :underline | :bar, blink?},
    # or nil for the user's choice from the config
    cursor_style: nil,
    autowrap: true,
    origin: false,
    insert: false,
    # character sets: G0 to G3 are :ascii, :dec_graphics, :uk or :latin1; gl says
    # which one is in use (SO, SI, LS2, LS3), and single_shift says which
    # one the next character alone comes from (SS2, SS3)
    g0: :ascii,
    g1: :ascii,
    g2: :ascii,
    g3: :ascii,
    gl: 0,
    single_shift: nil,
    # DECSC state, one per screen
    saved: %{main: nil, alt: nil},
    # the last cluster printed, {row, col, text}: REP repeats it, and a
    # combining mark that arrives in the next read joins it
    last_char: nil,
    # cluster id -> text, and back
    clusters: %{},
    cluster_ids: %{},
    next_cluster: @first_cluster,
    # block number => {row starts, rows}; block b holds rows b * 256 ..
    scrollback: %{},
    recent: [],
    scrollback_first: 0,
    history: 0,
    scrollback_max: 10_000,
    title: "",
    icon_name: "",
    # titles and icon names saved by XTWINOPS 22, newest first
    title_stack: [],
    icon_stack: [],
    # pens saved by XTPUSHSGR, newest first
    sgr_stack: [],
    # the theme (Guiltty.Theme), for answering what color something is
    theme: nil,
    # colors the program changed (OSC 4, 10, 11, 12): palette index => {r, g, b}
    palette: %{},
    fg_color: nil,
    bg_color: nil,
    cursor_color: nil,
    # answers that show the screen's contents (DECRQCRA): off unless asked
    # for, because a program at the other end of ssh could read the screen
    screen_reports: false,
    # the level DECSCL set, for DECRQSS to report
    conformance: {65, 1},
    # DECSACE: DECCARA and DECRARA take a rectangle, not a stream of cells
    sace_rect: false,
    # DEC modes XTSAVE remembered
    saved_modes: %{},
    # OSC 52: {target, text} for the window to put on the clipboard, once
    clipboard: nil,
    clipboard_target: :clipboard,
    # OSC 7: the program's working directory, as the URI it sent
    cwd_uri: nil,
    # OSC 8: where text printed now links to, and where earlier links are:
    # {row number, first col, last col, uri}, newest first
    link: nil,
    links: [],
    # OSC 133: row numbers where prompts start, newest first
    prompt_marks: [],
    # how many rows above the cursor were taken for the prompt, by a resize
    # the shell hasn't answered yet
    prompt_rows: nil,
    # mode 2026: the program is drawing; viewers wait for it to finish
    synchronized: false,
    # Kitty keyboard flags saved per screen, newest first
    kitty_stack: %{main: [], alt: []},
    input: @input_modes,
    # bytes to send back to the program (answers to its queries), newest first
    responses: [],
    # BEL arrived since the last take_bell/1
    bell: false,
    # the rows changed since the last take_dirty/1: a MapSet of row
    # numbers, or :all (a scroll moves every row; building a set of all of
    # them on every line feed was a fifth of the time spent printing)
    dirty: MapSet.new(),
    # {cols, bg, line}: the last blank line made, reused while the width
    # and background stay the same (each scroll needs one)
    blank: nil,
    # one cell's {width, height} in pixels, from the renderer, or nil
    # before it said: programs that draw images ask for it (CSI 14 t / 16 t)
    cell_pixels: nil,
    # images and where they show (Guiltty.Graphics)
    graphics: %Graphics{}
  ]

  @type t :: %__MODULE__{}
  @type color :: non_neg_integer()

  @tab_width 8

  def attr(:bold), do: @bold
  def attr(:dim), do: @dim
  def attr(:italic), do: @italic
  def attr(:underline), do: @underline
  def attr(:blink), do: @blink
  def attr(:inverse), do: @inverse
  def attr(:hidden), do: @hidden
  def attr(:strike), do: @strike
  def attr(:wide), do: @wide
  def attr(:spacer), do: @spacer
  def attr(:match), do: @match
  def attr(:current_match), do: @current_match
  def attr(:overline), do: @overline
  def attr(:protected), do: @protected
  def attr(:wrapped), do: @wrapped
  def attr(:link), do: @link

  @doc "The input modes a new terminal starts with."
  def default_input, do: @input_modes

  @spec indexed(0..255) :: color()
  def indexed(n), do: 0x01_000000 ||| n

  @spec rgb(0..255, 0..255, 0..255) :: color()
  def rgb(r, g, b), do: 0x02_000000 ||| r <<< 16 ||| g <<< 8 ||| b

  def cell_size, do: @cell_size

  @doc """
  A blank grid. Options: `:scrollback` (rows to keep, default 10,000),
  `:cell_pixels` (see `set_cell_pixels/2`), `:theme` (what the default colors
  are, for programs that ask) and `:screen_reports` (answer DECRQCRA).
  """
  @spec new(pos_integer(), pos_integer(), keyword()) :: t()
  def new(cols \\ 80, rows \\ 24, opts \\ []) do
    %__MODULE__{
      cols: cols,
      rows: rows,
      bottom: rows - 1,
      right: cols - 1,
      lines: blank_screen(cols, rows),
      scrollback_max: Keyword.get(opts, :scrollback, 10_000),
      cell_pixels: Keyword.get(opts, :cell_pixels),
      theme: Keyword.get(opts, :theme),
      screen_reports: Keyword.get(opts, :screen_reports, false)
    }
    |> all_dirty()
  end

  @doc """
  One cell's `{width, height}` in pixels, or nil when it isn't known (no
  renderer has said yet). It describes the window, not the text, so a
  reset keeps it.
  """
  def set_cell_pixels(grid, cell_pixels), do: %{grid | cell_pixels: cell_pixels}

  ## Reading

  @doc "The cursor as `{row, col}`, clamped to a visible cell."
  def cursor(grid), do: {grid.row, visible_col(grid)}

  # The column the cursor shows in: a pending wrap stays on the last cell.
  defp visible_col(%{pending_at: {row, col}, row: row, col: col}), do: col - 1
  defp visible_col(grid), do: min(grid.col, grid.cols - 1)

  @doc "Returns `[{row_index, row}]` for changed rows and clears the dirty set."
  def take_dirty(%{dirty: :all} = grid),
    do: take_dirty(%{grid | dirty: MapSet.new(0..(grid.rows - 1))})

  def take_dirty(grid) do
    rows = grid.dirty |> Enum.sort() |> Enum.map(&{&1, elem(grid.lines, &1)})
    {rows, %{grid | dirty: MapSet.new()}}
  end

  @doc "Whether any row changed since the last `take_dirty/1`."
  def dirty?(%{dirty: :all}), do: true
  def dirty?(grid), do: MapSet.size(grid.dirty) > 0

  @doc "Returns the bytes to send back to the program, oldest first, and clears them."
  def take_responses(grid), do: {Enum.reverse(grid.responses), %{grid | responses: []}}

  @doc "BEL: the program rang the bell."
  def ring(grid), do: %{grid | bell: true}

  @doc "Whether the bell rang since the last call, and the grid without it."
  def take_bell(grid), do: {grid.bell, %{grid | bell: false}}

  @doc "All rows as `[{row_index, row}]`, for a full redraw."
  def snapshot(grid), do: grid.lines |> Tuple.to_list() |> Enum.with_index(fn l, i -> {i, l} end)

  @doc "The screen as text, trailing spaces trimmed. For iex and tests."
  def dump(grid) do
    grid.lines
    |> Tuple.to_list()
    |> Enum.map_join("\n", &(grid |> line_text(&1) |> String.trim_trailing()))
  end

  @doc "The text of one row (a wide character's spacer adds nothing)."
  def line_text(grid, line) do
    for <<glyph::32, _::binary-size(10) <- line>>, into: "", do: glyph_text(grid, glyph)
  end

  @doc "The text a cell's glyph stands for."
  def glyph_text(_grid, 0), do: ""
  def glyph_text(_grid, glyph) when glyph < @first_cluster, do: <<glyph::utf8>>
  def glyph_text(grid, id), do: Map.get(grid.clusters, id, "\uFFFD")

  @doc "The cell at `{row, col}` as `{glyph, attrs, fg, bg}`."
  def cell(grid, row, col) do
    offset = col * @cell_size

    <<_::binary-size(^offset), g::32, attrs::16, fg::32, bg::32, _::binary>> =
      elem(grid.lines, row)

    {g, attrs, fg, bg}
  end

  @doc "Cluster definitions `[{id, text}]` with ids from `from` on (they're numbered in order)."
  def clusters_since(%{next_cluster: next}, from) when from >= next, do: []

  def clusters_since(grid, from) do
    for id <- max(from, @first_cluster)..(grid.next_cluster - 1)//1,
        do: {id, Map.fetch!(grid.clusters, id)}
  end

  ## Scrollback

  @doc "How many rows the scrollback holds."
  def scrollback_size(grid), do: grid.history - grid.scrollback_first

  @doc """
  Row number `n` (see "Scrollback" above), cut or padded to the screen's
  width, or nil if it's gone or doesn't exist.
  """
  def line(grid, n) do
    cond do
      n >= grid.history and n < grid.history + grid.rows -> elem(grid.lines, n - grid.history)
      n >= grid.scrollback_first and n < grid.history -> fit_line(saved_line(grid, n), grid.cols)
      true -> nil
    end
  end

  ## Text

  @doc """
  Writes text at the cursor with the current pen. Wraps at the right edge
  (unless autowrap is off), shifts the rest of the line right in insert
  mode, and translates through the DEC line-drawing set if it's active.

  ASCII takes a fast path, one byte per cell. Other text goes through the
  text NIF (c_src/text_nif.c), which makes cells of everything that can't
  join a neighbour; what might join is split into grapheme clusters here,
  each taking one cell, or two if it's wide.
  """
  def print(grid, text), do: print(grid, text, true)

  # print/2 without the text NIF: the reference its path is tested against.
  @doc false
  def print_in_elixir(grid, text), do: print(grid, text, false)

  defp print(grid, <<>>, _nif?), do: grid

  # SS2, SS3: the next character alone comes from G2 or G3.
  defp print(%{single_shift: set} = grid, text, nif?) when set != nil do
    {first, rest} = String.next_grapheme(text)

    grid =
      print(%{grid | single_shift: nil}, translate(first, Map.fetch!(grid, set)), :plain, nif?)

    print(grid, rest, nif?)
  end

  defp print(%{link: uri} = grid, text, nif?) when uri != nil do
    after_ = print(%{grid | link: nil}, text, nif?)
    remember_link(%{after_ | link: uri}, grid, uri)
  end

  defp print(grid, text, nif?), do: print(grid, translate(text, current_set(grid)), :plain, nif?)

  defp print(grid, <<>>, :plain, _nif?), do: grid

  defp print(%{margins?: true} = grid, text, :plain, _nif?) do
    case continued(grid, text) do
      {row, col, graphemes} ->
        put_in_margins(%{grid | row: row, col: col, pending_at: nil}, graphemes)

      nil ->
        put_in_margins(grid, String.graphemes(text))
    end
  end

  defp print(grid, text, :plain, nif?) do
    if ascii?(text),
      do: grid |> put_text(text) |> remember_last(binary_part(text, byte_size(text) - 1, 1)),
      else: put_clusters(grid, text, nif?)
  end

  defp current_set(%{gl: 0, g0: set}), do: set
  defp current_set(%{gl: 1, g1: set}), do: set
  defp current_set(%{gl: 2, g2: set}), do: set
  defp current_set(%{gl: 3, g3: set}), do: set

  # Text printed inside margins: a character at a time, wrapping at the right
  # margin to the left one. Past the right margin the screen's edge is the
  # limit instead.
  defp put_in_margins(grid, graphemes) do
    {grid, units} = intern_units(grid, graphemes)
    units |> Enum.reduce(grid, &put_in_margins_unit(&2, &1)) |> remember_margin_last(graphemes)
  end

  defp put_in_margins_unit(grid, {_glyph, width} = unit) do
    pending? = grid.pending_at == {grid.row, grid.col}
    inside? = pending? or grid.col <= grid.right
    edge = if inside?, do: grid.right, else: grid.cols - 1
    from = if pending?, do: grid.col, else: min(grid.col, grid.cols - 1)

    cond do
      from + width - 1 <= edge ->
        write_margin_unit(%{grid | col: from, pending_at: nil}, unit, edge)

      grid.autowrap ->
        %{grid | col: if(inside?, do: grid.left, else: 0), pending_at: nil}
        |> index()
        |> put_in_margins_unit(unit)

      true ->
        write_margin_unit(%{grid | col: max(edge - width + 1, 0), pending_at: nil}, unit, edge)
    end
  end

  defp write_margin_unit(grid, {_glyph, width} = unit, edge) do
    grid =
      grid
      |> then(&if(&1.insert, do: insert_chars(&1, width), else: &1))
      |> write_units([unit], width)

    next = grid.col + width

    cond do
      next <= edge -> %{grid | col: next}
      grid.autowrap -> %{grid | col: next, pending_at: {grid.row, next}}
      true -> %{grid | col: edge}
    end
  end

  defp remember_margin_last(grid, graphemes) do
    text = List.last(graphemes)
    col = visible_col(grid) + 1 - Unicode.width(text)
    %{grid | last_char: {grid.row, max(col, 0), text}}
  end

  @doc """
  Prints each text as a line of its own: print, carriage return, line
  feed, for each one. The same as doing that one by one, only faster when
  it can be: a program streaming short lines (`seq`, a log, `cat`) at the
  bottom of the screen makes thousands of these per read.

  The fast path builds the rows directly and scrolls the screen once, by
  all of them. It applies when the result is sure to be the same: the
  cursor at the start of a blank bottom row, the scroll region the whole
  screen, no insert mode, plain ASCII that fits on a line, no line-drawing
  set. The last line always goes the usual way, so whatever the usual way
  remembers (the last character, for REP) is as it would be.
  """
  def print_lines(grid, []), do: grid
  def print_lines(grid, [last]), do: print_line(grid, last)

  def print_lines(grid, [text | rest] = texts) do
    # The grid first: it's the cheap check. While it isn't ready (say the
    # screen is still filling up, or the line before was cut by the end of
    # a read and the cursor isn't at the start of a row), this line goes
    # the usual way, and the rest try again.
    with true <- batch_ready?(grid),
         {[_ | _] = plain, others} <- plain_prefix(texts, grid.cols) do
      grid |> batch_lines(plain) |> print_lines(others)
    else
      _ -> grid |> print_line(text) |> print_lines(rest)
    end
  end

  # The plain lines at the start, but never the last line: that one goes
  # the usual way.
  defp plain_prefix(texts, cols) do
    case Enum.split_while(texts, &plain_line?(&1, cols)) do
      {plain, []} -> Enum.split(plain, -1)
      split -> split
    end
  end

  defp print_line(grid, text), do: grid |> print(text) |> carriage_return() |> index()

  defp plain_line?(text, cols), do: byte_size(text) in 1..cols and ascii?(text)

  defp batch_ready?(grid) do
    %{row: row, rows: rows, bottom: bottom} = grid

    row == rows - 1 and bottom == rows - 1 and grid.top == 0 and grid.col == 0 and
      not grid.insert and current_set(grid) == :ascii and not grid.margins? and
      grid.link == nil and grid.single_shift == nil and not grid.input.newline_mode and
      elem(grid.lines, row) == elem(cached_blank(grid), 0)
  end

  # What print, CR and LF would do to each line in turn, done at once: the
  # rows are the texts in the current pen, padded with blank cells, and the
  # screen scrolls up by all of them together (the rows it pushes off the
  # top go to the scrollback, as one by one).
  #
  # Most of a big batch scrolls straight off the screen into the
  # scrollback, which keeps rows without their trailing blank cells. So
  # those rows are made short to begin with, and only the ones that stay
  # on screen are made full width.
  defp batch_lines(grid, texts) do
    {blank, grid} = cached_blank(grid)
    cells = &TextNif.ascii_cells(&1, grid.attrs, grid.fg, grid.bg)

    full =
      &(cells.(&1) <>
          binary_part(
            blank,
            byte_size(&1) * @cell_size,
            byte_size(blank) - byte_size(&1) * @cell_size
          ))

    # A space in this pen is a blank cell, so trimming would drop it too.
    blank_pen? = grid.attrs == 0 and grid.fg == @default_color
    short = &cells.(if blank_pen?, do: String.trim_trailing(&1, " "), else: &1)

    # The screen above the cursor's (blank) row, then the new rows, then a
    # blank row for the cursor: the first `n` of those leave the screen.
    above = grid.lines |> Tuple.to_list() |> Enum.drop(-1)
    n = length(texts)
    keep = length(above)

    {gone, screen} =
      if n <= keep do
        {gone, stay} = Enum.split(above, n)
        {gone, stay ++ Enum.map(texts, full) ++ [blank]}
      else
        {off, on} = Enum.split(texts, n - keep)
        {above ++ Enum.map(off, short), Enum.map(on, full) ++ [blank]}
      end

    grid = if grid.alt?, do: grid, else: save_lines(grid, gone)
    %{grid | lines: List.to_tuple(screen)} |> all_dirty() |> scrolled(n)
  end

  @doc "REP: prints the last printed character `n` more times."
  def repeat(%{last_char: nil} = grid, _n), do: grid

  def repeat(%{margins?: true} = grid, n) do
    {_row, _col, text} = grid.last_char
    put_in_margins(grid, List.duplicate(text, min(n, grid.cols * grid.rows)))
  end

  def repeat(grid, n) do
    {_row, _col, text} = grid.last_char
    n = min(n, grid.cols * grid.rows)

    if ascii?(text),
      do: put_text(grid, :binary.copy(text, n)),
      else: put_graphemes(grid, List.duplicate(text, n))
  end

  defp ascii?(text), do: TextNif.ascii?(text)

  # The cluster just printed ends right before the cursor.
  defp remember_last(grid, text) do
    col = min(grid.col, grid.cols) - Unicode.width(text)
    %{grid | last_char: {grid.row, max(col, 0), text}}
  end

  ## Clusters

  # A cluster can arrive in pieces: `e` in one read, its combining accent
  # in the next; half a flag, then the other half. So the last cluster
  # printed is segmented again together with the new text. If that changes
  # it, the two are printed again from that cluster's cell.
  #
  # (Regional indicators pair from the start of a run: 🇯🇯🇯 is a flag and
  # a lone 🇯. Only segmenting them together gets that right.)
  #
  # Otherwise the NIF cuts the text where clusters are sure to end. Its
  # cells are written as they are; the rest is segmented here. (Autowrap
  # off is rare, and piles text up in the last column: that stays here.)
  defp put_clusters(grid, text, nif?) do
    case continued(grid, text) do
      {row, col, graphemes} ->
        put_graphemes(%{grid | row: row, col: col}, graphemes)

      nil when nif? and grid.autowrap ->
        grid.attrs
        |> then(&TextNif.segments(text, &1, grid.fg, grid.bg))
        |> Enum.reduce(grid, fn
          {cells, cols}, grid -> put_cells(grid, cells, cols)
          text, grid -> put_graphemes(grid, String.graphemes(text))
        end)

      nil ->
        put_graphemes(grid, String.graphemes(text))
    end
  end

  defp put_graphemes(grid, graphemes) do
    {grid, units} = intern_units(grid, graphemes)
    grid |> put_units(units) |> remember_last(List.last(graphemes))
  end

  # Whether a cluster ends after `prev` depends only on `prev` and the
  # codepoint that follows (UAX #29's rules look back, never further
  # ahead), so the check segments just that, not the whole text.
  defp continued(%{last_char: {row, col, prev}} = grid, <<cp::utf8, _::binary>> = text) do
    width = Unicode.width(prev)

    with true <- grid.row == row and grid.col == col + width,
         {glyph, _, _, _} when glyph != 0 <- cell(grid, row, col),
         true <- glyph_text(grid, glyph) == prev,
         {first, _} when first != prev <- String.next_grapheme(prev <> <<cp::utf8>>) do
      {row, col, String.graphemes(prev <> text)}
    else
      _ -> nil
    end
  end

  defp continued(_grid, _text), do: nil

  defp intern_units(grid, graphemes) do
    Enum.map_reduce(graphemes, grid, fn text, grid ->
      {glyph, grid} = intern(grid, text)
      {{glyph, Unicode.width(text)}, grid}
    end)
    |> then(fn {units, grid} -> {grid, units} end)
  end

  # A one-codepoint cluster is its own glyph. Longer ones get an id.
  defp intern(grid, <<cp::utf8>>), do: {cp, grid}

  defp intern(grid, text) do
    case grid.cluster_ids do
      %{^text => id} ->
        {id, grid}

      _ when map_size(grid.clusters) >= @max_clusters or byte_size(text) > @max_cluster_bytes ->
        <<cp::utf8, _::binary>> = text
        {cp, grid}

      _ ->
        id = grid.next_cluster

        {id,
         %{
           grid
           | clusters: Map.put(grid.clusters, id, text),
             cluster_ids: Map.put(grid.cluster_ids, text, id),
             next_cluster: id + 1
         }}
    end
  end

  # Writes {glyph, width} units, as many per row as fit, wrapping between
  # rows. A wide character that doesn't fit in the last column wraps whole
  # and leaves that column blank.
  defp put_units(grid, []), do: grid

  defp put_units(%{col: col, cols: cols, autowrap: true} = grid, units) when col >= cols do
    grid |> mark_wrapped() |> Map.put(:col, 0) |> index() |> put_units(units)
  end

  defp put_units(%{autowrap: false} = grid, [{_glyph, width} = unit | rest])
       when grid.col + width > grid.cols do
    col = max(grid.cols - width, 0)

    grid
    |> Map.put(:col, col)
    |> write_units([unit], width)
    |> Map.put(:col, grid.cols - 1)
    |> put_units(rest)
  end

  defp put_units(grid, units) do
    case fitting(units, grid.cols - grid.col, [], 0) do
      {[], _width, [{_glyph, 2} | _] = rest} ->
        # A wide character with one column left: blank it and wrap.
        grid
        |> blank_cells(grid.row, grid.col, grid.cols)
        |> Map.put(:col, grid.cols)
        |> put_units(rest)

      {chunk, width, rest} ->
        grid
        |> then(&if(&1.insert, do: insert_chars(&1, width), else: &1))
        |> write_units(chunk, width)
        |> Map.put(:col, grid.col + width)
        |> put_units(rest)
    end
  end

  # Cells from the text NIF, `n` columns of them, written as many per row
  # as fit, like put_units/2: a wide character never splits across rows.
  defp put_cells(grid, <<>>, 0), do: grid

  defp put_cells(%{col: col, cols: cols} = grid, cells, n) when col >= cols do
    grid |> mark_wrapped() |> Map.put(:col, 0) |> index() |> put_cells(cells, n)
  end

  defp put_cells(grid, cells, n) do
    room = grid.cols - grid.col

    cond do
      n <= room ->
        grid |> write_chunk(cells, n) |> remember_cell(cells, n)

      # The last column would hold the left half of a wide character: it
      # wraps whole, and that column is left blank.
      wide?(cells, room - 1) ->
        len = (room - 1) * @cell_size
        <<chunk::binary-size(^len), rest::binary>> = cells

        grid
        |> write_chunk(chunk, room - 1)
        |> blank_cells(grid.row, grid.cols - 1, grid.cols)
        |> Map.put(:col, grid.cols)
        |> put_cells(rest, n - room + 1)

      true ->
        len = room * @cell_size
        <<chunk::binary-size(^len), rest::binary>> = cells
        grid |> write_chunk(chunk, room) |> put_cells(rest, n - room)
    end
  end

  defp write_chunk(grid, _chunk, 0), do: grid

  defp write_chunk(grid, chunk, n) do
    grid
    |> then(&if(&1.insert, do: insert_chars(&1, n), else: &1))
    |> replace_cells(grid.row, grid.col, chunk)
    |> Map.put(:col, grid.col + n)
  end

  # The last character written, from its cell: for REP, and for a
  # combining mark in the next read.
  defp remember_cell(grid, cells, n) do
    last = if spacer?(cells, n - 1), do: n - 2, else: n - 1
    <<glyph::32>> = binary_part(cells, last * @cell_size, 4)
    remember_last(grid, <<glyph::utf8>>)
  end

  defp fitting([{_g, w} = unit | rest], room, acc, width) when width + w <= room,
    do: fitting(rest, room, [unit | acc], width + w)

  defp fitting(rest, _room, acc, width), do: {Enum.reverse(acc), width, rest}

  defp write_units(grid, units, _width) do
    style = <<grid.fg::32, grid.bg::32>>

    cells =
      for {glyph, width} <- units, into: <<>> do
        case width do
          1 ->
            <<glyph::32, grid.attrs::16, style::binary>>

          2 ->
            <<glyph::32, grid.attrs ||| @wide::16, style::binary, 0::32,
              grid.attrs ||| @spacer::16, style::binary>>
        end
      end

    replace_cells(grid, grid.row, grid.col, cells)
  end

  # The last cell of the row says the text goes on in the next one. Writing
  # over that cell takes the mark away, as it should: the text changed.
  defp mark_wrapped(grid) do
    offset = (grid.cols - 1) * @cell_size + 4
    line = elem(grid.lines, grid.row)
    <<before::binary-size(^offset), attrs::16, after_::binary>> = line
    line = <<before::binary, attrs ||| @wrapped::16, after_::binary>>
    %{grid | lines: put_elem(grid.lines, grid.row, line)} |> dirty_rows(grid.row..grid.row)
  end

  ## ASCII

  defp put_text(grid, <<>>), do: grid

  defp put_text(%{col: col, cols: cols, autowrap: true} = grid, text) when col >= cols do
    grid |> mark_wrapped() |> Map.put(:col, 0) |> index() |> put_text(text)
  end

  # Autowrap off: everything past the edge lands on the last cell.
  defp put_text(%{autowrap: false, col: col, cols: cols} = grid, text) when col >= cols - 1 do
    last = binary_part(text, byte_size(text) - 1, 1)
    grid |> Map.put(:col, cols - 1) |> write_cells(last) |> Map.put(:col, cols - 1)
  end

  defp put_text(grid, text) do
    n = min(grid.cols - grid.col, byte_size(text))
    <<chunk::binary-size(^n), rest::binary>> = text

    grid
    |> then(&if(&1.insert, do: insert_chars(&1, n), else: &1))
    |> write_cells(chunk)
    |> Map.put(:col, grid.col + n)
    |> put_text(rest)
  end

  defp write_cells(grid, chunk) do
    cells = TextNif.ascii_cells(chunk, grid.attrs, grid.fg, grid.bg)
    replace_cells(grid, grid.row, grid.col, cells)
  end

  # DEC Special Graphics, the line-drawing set ncurses selects with ESC ( 0:
  # ASCII letters stand for box pieces. Here they become the Unicode ones.
  @dec_graphics %{
    ?` => ?◆,
    ?a => ?▒,
    ?b => ?␉,
    ?c => ?␌,
    ?d => ?␍,
    ?e => ?␊,
    ?f => ?°,
    ?g => ?±,
    ?h => ?␤,
    ?i => ?␋,
    ?j => ?┘,
    ?k => ?┐,
    ?l => ?┌,
    ?m => ?└,
    ?n => ?┼,
    ?o => ?⎺,
    ?p => ?⎻,
    ?q => ?─,
    ?r => ?⎼,
    ?s => ?⎽,
    ?t => ?├,
    ?u => ?┤,
    ?v => ?┴,
    ?w => ?┬,
    ?x => ?│,
    ?y => ?≤,
    ?z => ?≥,
    ?{ => ?π,
    ?| => ?≠,
    ?} => ?£,
    ?~ => ?·
  }

  defp translate(text, :ascii), do: text
  defp translate(text, :uk), do: String.replace(text, "#", "£")

  # ISO Latin-1's upper half, where ASCII is: ! is ¡, A is Á.
  defp translate(text, :latin1) do
    for <<c::utf8 <- text>>, into: "", do: <<if(c in 0x20..0x7F, do: c + 0x80, else: c)::utf8>>
  end

  defp translate(text, :dec_graphics) do
    for <<c::utf8 <- text>>, into: "", do: <<Map.get(@dec_graphics, c, c)::utf8>>
  end

  def designate(grid, which, set) when which in [:g0, :g1, :g2, :g3],
    do: Map.put(grid, which, set)

  def shift(grid, gl), do: %{grid | gl: gl}

  @doc "SS2, SS3: the next character alone comes from `:g2` or `:g3`."
  def single_shift(grid, set), do: %{grid | single_shift: set}

  ## Cursor

  def carriage_return(%{margins?: false} = grid), do: %{grid | col: 0}

  # To the left margin; from outside it, to the screen's edge (unless origin
  # mode keeps the cursor inside).
  def carriage_return(grid) do
    col = if visible_col(grid) >= grid.left or grid.origin, do: grid.left, else: 0
    %{grid | col: col, pending_at: nil}
  end

  @doc "Backspace: one cell left. See `move_back/2`."
  def backspace(grid), do: move_back(grid, 1)

  @doc """
  CUB, and backspace: `n` cells left, stopping at the margin. With reverse
  wrap (mode 45) and autowrap, it goes on to the end of the row above, but
  only over a row that wrapped: as in xterm, the start of the line is as far
  as text flows back. A wrap that's pending counts as the first cell back.
  """
  def move_back(%{reverse_wrap_all: true, autowrap: true} = grid, n), do: wrap_back_from(grid, n)
  def move_back(%{reverse_wrap: true, autowrap: true} = grid, n), do: wrap_back_from(grid, n)
  def move_back(grid, n), do: move_by(grid, 0, -n)

  defp wrap_back_from(grid, n) do
    pending? = grid.col >= grid.cols or grid.pending_at == {grid.row, grid.col}
    n = if pending?, do: n - 1, else: n
    wrap_back(%{grid | col: visible_col(grid), pending_at: nil}, n)
  end

  defp wrap_back(grid, 0), do: grid

  defp wrap_back(grid, n) do
    left = if grid.col >= grid.left, do: grid.left, else: 0
    width = grid.col - left

    cond do
      n <= width ->
        %{grid | col: grid.col - n}

      # Mode 1045, the original reverse wrap: over any row, from the top of
      # the scroll region around to its bottom.
      grid.reverse_wrap_all ->
        row = if grid.row == grid.top, do: grid.bottom, else: max(grid.row - 1, 0)
        wrap_back(%{grid | row: row, col: grid.right}, n - width - 1)

      grid.row > grid.top and row_wrapped?(elem(grid.lines, grid.row - 1)) ->
        wrap_back(%{grid | row: grid.row - 1, col: grid.right}, n - width - 1)

      true ->
        %{grid | col: left}
    end
  end

  @doc "HT: to the next tab stop, or the margin if there's none before it."
  def tab(grid), do: tab(grid, 1)

  @doc "CHT: `n` tab stops forward."
  def tab(grid, 0), do: grid

  def tab(grid, n) do
    col = visible_col(grid)
    edge = if col <= grid.right, do: grid.right, else: grid.cols - 1
    tab(%{grid | col: min(next_stop(grid.tabs, col) || edge, edge), pending_at: nil}, n - 1)
  end

  @doc "CBT: `n` tab stops back."
  def back_tab(grid, 0), do: grid

  def back_tab(grid, n) do
    col = visible_col(grid)
    back_tab(%{grid | col: max(prev_stop(grid.tabs, col) || 0, 0), pending_at: nil}, n - 1)
  end

  defp next_stop(nil, col), do: (div(col, @tab_width) + 1) * @tab_width
  defp next_stop(stops, col), do: Enum.find(stops, &(&1 > col))

  defp prev_stop(nil, 0), do: nil
  defp prev_stop(nil, col), do: div(col - 1, @tab_width) * @tab_width
  defp prev_stop(stops, col), do: stops |> Enum.reverse() |> Enum.find(&(&1 < col))

  # The widest grid the renderer can show: a resize keeps these.
  defp default_stops, do: Enum.to_list(0..4095//@tab_width)

  @doc "HTS: a tab stop at the cursor's column."
  def set_tab_stop(grid) do
    stops = grid.tabs || default_stops()
    %{grid | tabs: Enum.sort(Enum.uniq([visible_col(grid) | stops]))}
  end

  @doc "TBC: 0 clears the tab stop at the cursor, 3 clears them all."
  def clear_tab_stop(grid, 0),
    do: %{grid | tabs: List.delete(grid.tabs || default_stops(), visible_col(grid))}

  def clear_tab_stop(grid, 3), do: %{grid | tabs: []}
  def clear_tab_stop(grid, _mode), do: grid

  @doc """
  Moves to `{row, col}`, clamped to the screen. In origin mode, they count
  from the corner of the scroll region and margins, and stay inside them.
  """
  def move_to(grid, row, col), do: grid |> move_row(row) |> move_col(col)

  @doc "VPA: to a row, keeping the column."
  def move_row(%{origin: true} = grid, row),
    do: %{grid | row: clamp(grid.top + row, grid.top, grid.bottom), pending_at: nil}

  def move_row(grid, row), do: %{grid | row: clamp(row, 0, grid.rows - 1), pending_at: nil}

  @doc "CHA: to a column, keeping the row."
  def move_col(%{origin: true} = grid, col),
    do: %{grid | col: clamp(grid.left + col, grid.left, grid.right), pending_at: nil}

  def move_col(grid, col), do: %{grid | col: clamp(col, 0, grid.cols - 1), pending_at: nil}

  @doc """
  Moves by a relative amount. Moves stop at the scroll region's and the
  margins' edge when the cursor is inside them, and at the screen's otherwise.
  """
  def move_by(grid, drow, dcol) do
    {lo, hi} =
      if grid.row >= grid.top and grid.row <= grid.bottom,
        do: {grid.top, grid.bottom},
        else: {0, grid.rows - 1}

    col = visible_col(grid)
    left = if col >= grid.left, do: grid.left, else: 0
    right = if col <= grid.right, do: grid.right, else: grid.cols - 1

    %{
      grid
      | row: clamp(grid.row + drow, lo, hi),
        col: clamp(col + dcol, left, right),
        pending_at: nil
    }
  end

  @doc "The cursor's row for reports (CPR): relative to the region in origin mode."
  def report_row(%{origin: true} = grid), do: grid.row - grid.top
  def report_row(grid), do: grid.row

  @doc "The cursor's column for reports: relative to the margin in origin mode."
  def report_col(%{origin: true} = grid), do: visible_col(grid) - grid.left
  def report_col(grid), do: visible_col(grid)

  @doc "Mode 12: whether the program wants the cursor blinking."
  def set_cursor_blink(grid, on?), do: %{grid | cursor_blink: on?}

  def set_cursor_visible(grid, visible), do: %{grid | cursor_visible: visible}

  @doc "DECSCUSR: the cursor's shape, or nil to go back to the user's."
  def set_cursor_style(grid, style), do: %{grid | cursor_style: style}

  @doc "DECSC: saves the cursor, the pen, origin mode and the character sets."
  def save_cursor(grid) do
    saved =
      Map.take(
        grid,
        [:row, :col, :attrs, :fg, :bg, :origin] ++ [:g0, :g1, :g2, :g3, :gl]
      )

    %{grid | saved: Map.put(grid.saved, screen(grid), saved)}
  end

  @doc "DECRC: restores what DECSC saved, or homes the cursor if nothing was."
  def restore_cursor(grid) do
    case grid.saved[screen(grid)] do
      nil ->
        %{
          grid
          | row: 0,
            col: 0,
            attrs: 0,
            fg: 0,
            bg: 0,
            origin: false,
            g0: :ascii,
            g1: :ascii,
            g2: :ascii,
            g3: :ascii,
            gl: 0,
            pending_at: nil
        }

      saved ->
        grid = Map.merge(grid, saved)

        %{
          grid
          | row: min(grid.row, grid.rows - 1),
            col: min(grid.col, grid.cols),
            pending_at: nil
        }
    end
  end

  defp screen(%{alt?: true}), do: :alt
  defp screen(_), do: :main

  ## Scrolling

  @doc """
  Line feed (IND): down one row, scrolling the region up at its bottom.
  Outside the margins there's nothing to scroll.
  """
  def index(%{margins?: true} = grid) do
    cond do
      grid.row == grid.bottom -> if in_margins?(grid), do: scroll_up(grid, 1), else: grid
      grid.row < grid.rows - 1 -> %{grid | row: grid.row + 1}
      true -> grid
    end
  end

  def index(%{row: row, bottom: row} = grid), do: scroll_up(grid, 1)
  def index(%{row: row, rows: rows} = grid) when row < rows - 1, do: %{grid | row: row + 1}
  def index(grid), do: grid

  @doc "Reverse index (RI): up one row, scrolling the region down at its top."
  def reverse_index(%{margins?: true} = grid) do
    cond do
      grid.row == grid.top -> if in_margins?(grid), do: scroll_down(grid, 1), else: grid
      grid.row > 0 -> %{grid | row: grid.row - 1}
      true -> grid
    end
  end

  def reverse_index(%{row: row, top: row} = grid), do: scroll_down(grid, 1)
  def reverse_index(%{row: row} = grid) when row > 0, do: %{grid | row: row - 1}
  def reverse_index(grid), do: grid

  @doc "SU: moves the region's rows up by `n`; blank rows enter at its bottom."
  def scroll_up(grid, n), do: shift_rows(grid, grid.top, grid.bottom, -n)

  @doc "SD: moves the region's rows down by `n`; blank rows enter at its top."
  def scroll_down(grid, n), do: shift_rows(grid, grid.top, grid.bottom, n)

  @doc "IL: inserts `n` blank rows at the cursor, pushing the rest of the region down."
  def insert_lines(grid, n) do
    if in_region?(grid) and in_margins?(grid),
      do: grid |> shift_rows(grid.row, grid.bottom, n) |> Map.put(:col, grid.left),
      else: grid
  end

  @doc "DL: deletes `n` rows at the cursor, pulling the rest of the region up."
  def delete_lines(grid, n) do
    if in_region?(grid) and in_margins?(grid),
      do: grid |> shift_rows(grid.row, grid.bottom, -n) |> Map.put(:col, grid.left),
      else: grid
  end

  @doc "DECSTBM: sets the scroll region (0-based, inclusive) and homes the cursor."
  def set_region(grid, top, bottom) do
    bottom = min(bottom, grid.rows - 1)

    if top < bottom,
      do: %{grid | top: top, bottom: bottom} |> move_to(0, 0),
      else: grid
  end

  @doc """
  DECSLRM: sets the left and right margins (0-based, inclusive) and homes
  the cursor. Nothing happens unless they leave at least two columns.
  """
  def set_margins(grid, left, right) do
    right = min(right, grid.cols - 1)

    if left < right do
      %{grid | left: left, right: right, margins?: left > 0 or right < grid.cols - 1}
      |> move_to(0, 0)
    else
      grid
    end
  end

  @doc "DECLRMM: whether CSI s sets margins. Turning it off drops them."
  def set_margin_mode(grid, true), do: %{grid | lrmm: true}

  def set_margin_mode(grid, false),
    do: %{grid | lrmm: false, left: 0, right: grid.cols - 1, margins?: false}

  defp in_region?(grid), do: grid.row >= grid.top and grid.row <= grid.bottom

  defp in_margins?(grid) do
    col = visible_col(grid)
    col >= grid.left and col <= grid.right
  end

  @doc "SL (`n` negative) or SR: moves the columns inside the margins sideways."
  def shift_columns(grid, n), do: move_columns(grid, grid.left, grid.right, n)

  @doc "DECIC: inserts `n` blank columns at the cursor, inside the margins."
  def insert_columns(grid, n) do
    if in_region?(grid) and in_margins?(grid),
      do: move_columns(grid, visible_col(grid), grid.right, n),
      else: grid
  end

  @doc "DECDC: deletes `n` columns at the cursor, inside the margins."
  def delete_columns(grid, n) do
    if in_region?(grid) and in_margins?(grid),
      do: move_columns(grid, visible_col(grid), grid.right, -n),
      else: grid
  end

  @doc "DECBI: left one cell; at the left margin, the columns move right instead."
  def back_index(grid) do
    col = visible_col(grid)

    cond do
      col == grid.left and in_region?(grid) -> shift_columns(grid, 1)
      col > 0 -> %{grid | col: col - 1, pending_at: nil}
      true -> grid
    end
  end

  @doc "DECFI: right one cell; at the right margin, the columns move left instead."
  def forward_index(grid) do
    col = visible_col(grid)

    cond do
      col == grid.right and in_region?(grid) -> shift_columns(grid, -1)
      col < grid.cols - 1 -> %{grid | col: col + 1, pending_at: nil}
      true -> grid
    end
  end

  # The cells in columns from..to of every row of the scroll region move by
  # n (positive = right); blank cells fill in behind.
  defp move_columns(grid, from, to, n) do
    size = to - from + 1
    n = clamp(n, -size, size)
    blank = blank_cell(grid.bg)

    Enum.reduce(grid.top..grid.bottom, grid, fn row, grid ->
      cells = row_slice(grid, row, from, size)
      keep = (size - abs(n)) * @cell_size

      moved =
        if n >= 0 do
          :binary.copy(blank, n) <> binary_part(cells, 0, keep)
        else
          binary_part(cells, -n * @cell_size, keep) <> :binary.copy(blank, -n)
        end

      replace_cells(grid, row, from, moved)
    end)
  end

  defp row_slice(grid, row, col, n),
    do: binary_part(elem(grid.lines, row), col * @cell_size, n * @cell_size)

  # Moves rows from..to by n (positive = down), filling with blank rows.
  # Rows pushed off the top of the whole main screen go to the scrollback.
  #
  # The usual case, a line feed at the bottom of the whole screen, is one
  # row up: tuple operations, without going through a list.
  defp shift_rows(%{margins?: true} = grid, from, to, n) do
    size = to - from + 1
    n = clamp(n, -size, size)
    width = grid.right - grid.left + 1
    blank = :binary.copy(blank_cell(grid.bg), width)
    region = for row <- from..to, do: row_slice(grid, row, grid.left, width)

    region =
      if n >= 0,
        do: List.duplicate(blank, n) ++ Enum.take(region, size - n),
        else: Enum.drop(region, -n) ++ List.duplicate(blank, -n)

    region
    |> Enum.with_index(from)
    |> Enum.reduce(grid, fn {cells, row}, grid -> replace_cells(grid, row, grid.left, cells) end)
  end

  defp shift_rows(%{rows: rows} = grid, 0, to, -1) when to == rows - 1 do
    grid = if grid.alt?, do: grid, else: save_lines(grid, [elem(grid.lines, 0)])
    {blank, grid} = cached_blank(grid)
    lines = grid.lines |> Tuple.delete_at(0) |> Tuple.insert_at(rows - 1, blank)
    %{grid | lines: lines} |> all_dirty() |> scrolled(1)
  end

  defp shift_rows(grid, from, to, n) do
    size = to - from + 1
    n = clamp(n, -size, size)
    {blank, grid} = cached_blank(grid)
    {before, rest} = grid.lines |> Tuple.to_list() |> Enum.split(from)
    {region, after_} = Enum.split(rest, size)

    grid =
      if n < 0 and from == 0 and to == grid.rows - 1 and not grid.alt?,
        do: save_lines(grid, Enum.take(region, -n)),
        else: grid

    region =
      if n >= 0,
        do: List.duplicate(blank, n) ++ Enum.take(region, size - n),
        else: Enum.drop(region, -n) ++ List.duplicate(blank, -n)

    lines = List.to_tuple(before ++ region ++ after_)
    grid = %{grid | lines: lines} |> dirty_rows(from..to)
    # Images scroll with the whole screen (not inside a smaller region).
    if from == 0 and to == grid.rows - 1, do: scrolled(grid, -n), else: grid
  end

  # The screen moved `n` lines up: images move with it. Nothing to do
  # (the usual case) when none is placed.
  defp scrolled(%{graphics: %{placements: []}} = grid, _n), do: grid

  defp scrolled(grid, n),
    do: %{grid | graphics: Graphics.scroll(grid.graphics, screen(grid), n)}

  # A blank line in the current width and background, made once and reused:
  # binaries are immutable, so every row that's blank can share it.
  defp cached_blank(%{blank: {cols, bg, line}, cols: cols, bg: bg} = grid), do: {line, grid}

  defp cached_blank(grid) do
    line = blank_line(grid.cols, grid.bg)
    {line, %{grid | blank: {grid.cols, grid.bg, line}}}
  end

  defp save_lines(%{scrollback_max: 0} = grid, _lines), do: grid

  defp save_lines(grid, lines) do
    grid = Enum.reduce(lines, grid, &save_line(&2, &1))
    first = max(grid.scrollback_first, grid.history - grid.scrollback_max)
    # Drop whole blocks once all their rows are older than the first kept.
    gone = div(first, @block) - 1

    blocks =
      Enum.reduce(
        div(grid.scrollback_first, @block)..gone//1,
        grid.scrollback,
        &Map.delete(&2, &1)
      )

    %{grid | scrollback: blocks, scrollback_first: first}
  end

  # Rows are kept without their trailing blank cells, from the moment
  # they're saved: the fast path (print_lines/2) saves rows already short.
  defp save_line(grid, line) do
    grid = %{grid | recent: [trim_line(line) | grid.recent], history: grid.history + 1}
    if rem(grid.history, @block) == 0, do: seal(grid), else: grid
  end

  # The last 256 rows become one block.
  defp seal(grid) do
    rows = Enum.reverse(grid.recent)
    starts = rows |> Enum.scan(0, &(byte_size(&1) + &2)) |> then(&[0 | &1]) |> List.to_tuple()
    block = div(grid.history - 1, @block)

    %{
      grid
      | scrollback: Map.put(grid.scrollback, block, {starts, IO.iodata_to_binary(rows)}),
        recent: []
    }
  end

  # A saved row, as stored (maybe shorter than the screen).
  defp saved_line(grid, n) do
    if n >= grid.history - length(grid.recent) do
      Enum.at(grid.recent, grid.history - 1 - n)
    else
      {starts, rows} = Map.fetch!(grid.scrollback, div(n, @block))
      i = rem(n, @block)
      binary_part(rows, elem(starts, i), elem(starts, i + 1) - elem(starts, i))
    end
  end

  # Most rows are short: keep them without their trailing blank cells.
  #
  # Where the content ends is found by binary search: "are the cells from
  # here on all blank?" is true from some cell to the end, and each try is
  # one binary comparison (a memcmp). About 7 tries for a 120-cell row,
  # where :binary.longest_common_suffix/1 took a fifth of all the time
  # spent printing.
  defp trim_line(line) do
    cells = div(byte_size(line), @cell_size)

    blanks =
      if byte_size(line) <= byte_size(@blanks),
        do: binary_part(@blanks, 0, byte_size(line)),
        else: :binary.copy(@blank, cells)

    keep = content_end(line, blanks, 0, cells)
    binary_part(line, 0, keep * @cell_size)
  end

  # The first cell from which everything is blank, between lo and hi.
  defp content_end(_line, _blanks, lo, lo), do: lo

  defp content_end(line, blanks, lo, hi) do
    mid = div(lo + hi, 2)
    from = mid * @cell_size
    tail = byte_size(line) - from

    if binary_part(line, from, tail) == binary_part(blanks, from, tail),
      do: content_end(line, blanks, lo, mid),
      else: content_end(line, blanks, mid + 1, hi)
  end

  ## Characters in a line

  @doc """
  ICH: inserts `n` blank cells at the cursor; cells pushed past the right
  margin are lost. Outside the margins it does nothing.
  """
  def insert_chars(grid, n) do
    col = visible_col(grid)

    if col > grid.right or (grid.margins? and col < grid.left) do
      grid
    else
      room = grid.right - col + 1
      n = min(n, room)
      moved = row_slice(grid, grid.row, col, room - n)
      replace_cells(grid, grid.row, col, :binary.copy(blank_cell(grid.bg), n) <> moved)
    end
  end

  @doc """
  DCH: deletes `n` cells at the cursor; blank cells enter at the right margin.
  Outside the margins it does nothing.
  """
  def delete_chars(grid, n) do
    col = visible_col(grid)

    if col > grid.right or (grid.margins? and col < grid.left) do
      grid
    else
      room = grid.right - col + 1
      n = min(n, room)
      moved = row_slice(grid, grid.row, col + n, room - n)
      replace_cells(grid, grid.row, col, moved <> :binary.copy(blank_cell(grid.bg), n))
    end
  end

  ## Erasing
  #
  # Erased cells take the current background color ("back color erase", the
  # `bce` capability in xterm-256color's terminfo entry), with no attributes.

  @doc "ED: 0 = cursor to end, 1 = start to cursor, 2 = the screen, 3 = the scrollback."
  def erase_display(grid, 0) do
    grid = erase_line(grid, 0)
    Enum.reduce((grid.row + 1)..(grid.rows - 1)//1, grid, &blank_row(&2, &1))
  end

  def erase_display(grid, 1) do
    grid = erase_line(grid, 1)
    Enum.reduce(0..(grid.row - 1)//1, grid, &blank_row(&2, &1))
  end

  def erase_display(grid, 2) do
    grid = Enum.reduce(0..(grid.rows - 1), grid, &blank_row(&2, &1))
    %{grid | graphics: Graphics.clear_screen(grid.graphics, screen(grid), grid.rows)}
  end

  # 3: the scrollback (what `clear` sends after erasing the screen).
  def erase_display(grid, 3) do
    %{
      grid
      | scrollback: %{},
        recent: [],
        scrollback_first: grid.history,
        graphics: Graphics.clear_scrollback(grid.graphics),
        links: Enum.filter(grid.links, fn {n, _, _, _} -> n >= grid.history end),
        prompt_marks: Enum.filter(grid.prompt_marks, &(&1 >= grid.history))
    }
  end

  def erase_display(grid, _mode), do: grid

  @doc "EL: 0 = cursor to end of line, 1 = start to cursor, 2 = whole line."
  def erase_line(grid, 0), do: blank_cells(grid, grid.row, visible_col(grid), grid.cols)
  def erase_line(grid, 1), do: blank_cells(grid, grid.row, 0, visible_col(grid) + 1)
  def erase_line(grid, 2), do: blank_row(grid, grid.row)
  def erase_line(grid, _mode), do: grid

  @doc "ECH: erases `n` cells from the cursor, without moving it."
  def erase_chars(grid, n) do
    from = visible_col(grid)
    blank_cells(grid, grid.row, from, min(from + n, grid.cols))
  end

  @doc "DECSED: as ED, but protected cells (DECSCA) stay."
  def selective_erase_display(grid, 0) do
    grid = selective_erase_line(grid, 0)
    Enum.reduce((grid.row + 1)..(grid.rows - 1)//1, grid, &selective_blank(&2, &1, 0, grid.cols))
  end

  def selective_erase_display(grid, 1) do
    grid = selective_erase_line(grid, 1)
    Enum.reduce(0..(grid.row - 1)//1, grid, &selective_blank(&2, &1, 0, grid.cols))
  end

  def selective_erase_display(grid, 2),
    do: Enum.reduce(0..(grid.rows - 1), grid, &selective_blank(&2, &1, 0, grid.cols))

  def selective_erase_display(grid, _mode), do: grid

  @doc "DECSEL: as EL, but protected cells (DECSCA) stay."
  def selective_erase_line(grid, 0),
    do: selective_blank(grid, grid.row, visible_col(grid), grid.cols)

  def selective_erase_line(grid, 1),
    do: selective_blank(grid, grid.row, 0, visible_col(grid) + 1)

  def selective_erase_line(grid, 2), do: selective_blank(grid, grid.row, 0, grid.cols)
  def selective_erase_line(grid, _mode), do: grid

  defp selective_blank(grid, _row, from, to) when from >= to, do: grid

  defp selective_blank(grid, row, from, to) do
    blank = blank_cell(grid.bg)
    cells = row_slice(grid, row, from, to - from)

    kept =
      for <<cell::binary-size(@cell_size) <- cells>>, into: <<>> do
        <<_glyph::32, attrs::16, _::binary>> = cell
        if (attrs &&& @protected) != 0, do: cell, else: blank
      end

    replace_cells(grid, row, from, kept)
  end

  @doc "DECSCA: whether what's printed from now on is protected."
  def set_protected(grid, true), do: %{grid | attrs: grid.attrs ||| @protected}
  def set_protected(grid, false), do: %{grid | attrs: grid.attrs &&& bnot(@protected)}

  ## Rectangles (DECFRA and friends)
  #
  # {top, left, bottom, right}, 0-based and inclusive, on the whole screen.

  @doc "DECFRA: fills a rectangle with a character, in the current pen."
  def fill_rect(grid, codepoint, {top, left, bottom, right}) do
    cell = <<codepoint::32, grid.attrs::16, grid.fg::32, grid.bg::32>>
    cells = :binary.copy(cell, right - left + 1)
    Enum.reduce(top..bottom, grid, &replace_cells(&2, &1, left, cells))
  end

  @doc "DECERA: erases a rectangle."
  def erase_rect(grid, {top, left, bottom, right}) do
    cells = :binary.copy(blank_cell(grid.bg), right - left + 1)
    Enum.reduce(top..bottom, grid, &replace_cells(&2, &1, left, cells))
  end

  @doc "DECSERA: erases a rectangle, leaving protected cells."
  def selective_erase_rect(grid, {top, left, bottom, right}),
    do: Enum.reduce(top..bottom, grid, &selective_blank(&2, &1, left, right + 1))

  @doc "DECCRA: copies a rectangle so its corner lands at `{to_row, to_col}`, clipped to the screen."
  def copy_rect(grid, {top, left, bottom, right}, {to_row, to_col}) do
    width = min(right - left + 1, grid.cols - to_col)
    height = min(bottom - top + 1, grid.rows - to_row)

    if width <= 0 or height <= 0 do
      grid
    else
      rows = for i <- 0..(height - 1), do: {to_row + i, row_slice(grid, top + i, left, width)}

      Enum.reduce(rows, grid, fn {row, cells}, grid -> replace_cells(grid, row, to_col, cells) end)
    end
  end

  @doc """
  DECCARA and DECRARA: runs `fun` on the attributes of each cell of a
  rectangle (or, with `stream: true`, from its first to its last cell, the
  way text flows).
  """
  def change_rect_attrs(grid, {top, left, bottom, right}, fun, opts \\ []) do
    stream? = Keyword.get(opts, :stream, false)

    Enum.reduce(top..bottom, grid, fn row, grid ->
      from = if stream? and row > top, do: 0, else: left
      to = if stream? and row < bottom, do: grid.cols - 1, else: right
      cells = row_slice(grid, row, from, to - from + 1)

      changed =
        for <<glyph::32, attrs::16, colors::binary-size(8) <- cells>>, into: <<>> do
          <<glyph::32, fun.(attrs)::16, colors::binary>>
        end

      replace_cells(grid, row, from, changed)
    end)
  end

  @doc """
  DECRQCRA's checksum of a rectangle: the sum of its cells' characters, as a
  VT420 computes it (the negative of the sum, in 16 bits). Only asked for
  when `screen_reports` is on: it lets a program read the screen.
  """
  def checksum_rect(grid, {top, left, bottom, right}) do
    sum =
      Enum.reduce(top..bottom, 0, fn row, sum ->
        cells = row_slice(grid, row, left, right - left + 1)

        for <<glyph::32, _::binary-size(10) <- cells>>, reduce: sum do
          sum -> sum + rem(checksum_glyph(grid, glyph), 0x10000)
        end
      end)

    band(0x10000 - band(sum, 0xFFFF), 0xFFFF)
  end

  defp checksum_glyph(_grid, glyph) when glyph < @first_cluster, do: glyph

  defp checksum_glyph(grid, glyph) do
    <<first::utf8, _::binary>> = glyph_text(grid, glyph)
    first
  end

  @doc "DECALN: fills the screen with E (used by vttest to check alignment)."
  def fill_with_e(grid) do
    line = :binary.copy(<<?E::32, 0::16, 0::32, 0::32>>, grid.cols)

    %{
      grid
      | lines: Tuple.duplicate(line, grid.rows),
        row: 0,
        col: 0,
        top: 0,
        bottom: grid.rows - 1,
        left: 0,
        right: grid.cols - 1,
        margins?: false,
        pending_at: nil
    }
    |> all_dirty()
  end

  ## Modes and the pen

  def set_pen(grid, attrs, fg, bg),
    do: %{grid | attrs: attrs ||| (grid.attrs &&& @sticky), fg: fg, bg: bg}

  # Turning autowrap off ends a pending wrap: the cursor is simply on the
  # last cell (DEC STD 070).
  def set_mode(grid, :autowrap, false),
    do: %{grid | autowrap: false, col: visible_col(grid), pending_at: nil}

  def set_mode(grid, mode, value)
      when mode in [:autowrap, :insert, :reverse_wrap, :reverse_wrap_all],
      do: Map.put(grid, mode, value)

  @doc "DECSCNM: the whole screen in reverse video."
  def set_reverse_video(%{reverse_video: on?} = grid, on?), do: grid
  def set_reverse_video(grid, on?), do: %{grid | reverse_video: on?} |> all_dirty()

  @doc "XTPUSHSGR: saves the pen."
  def push_sgr(grid) do
    pen = {grid.attrs, grid.fg, grid.bg}
    %{grid | sgr_stack: Enum.take([pen | grid.sgr_stack], @max_stack)}
  end

  @doc "XTPOPSGR: restores the pen saved last."
  def pop_sgr(%{sgr_stack: []} = grid), do: grid

  def pop_sgr(%{sgr_stack: [{attrs, fg, bg} | rest]} = grid),
    do: %{grid | attrs: attrs, fg: fg, bg: bg, sgr_stack: rest}

  @doc "DECOM: origin mode; switching it homes the cursor."
  def set_origin(grid, on?), do: %{grid | origin: on?} |> move_to(0, 0)

  def set_input(grid, mode, value), do: %{grid | input: Map.put(grid.input, mode, value)}

  def set_title(grid, title), do: %{grid | title: title}
  def set_icon_name(grid, name), do: %{grid | icon_name: name}

  @doc "XTWINOPS 22: saves the title (`:title`), the icon name (`:icon`), or both (`:both`)."
  def push_title(grid, :both), do: grid |> push_title(:icon) |> push_title(:title)

  def push_title(grid, :title),
    do: %{grid | title_stack: Enum.take([grid.title | grid.title_stack], @max_stack)}

  def push_title(grid, :icon),
    do: %{grid | icon_stack: Enum.take([grid.icon_name | grid.icon_stack], @max_stack)}

  @doc "XTWINOPS 23: restores what `push_title/2` saved last."
  def pop_title(grid, :both), do: grid |> pop_title(:icon) |> pop_title(:title)
  def pop_title(%{title_stack: []} = grid, :title), do: grid
  def pop_title(%{icon_stack: []} = grid, :icon), do: grid

  def pop_title(%{title_stack: [title | rest]} = grid, :title),
    do: %{grid | title: title, title_stack: rest}

  def pop_title(%{icon_stack: [name | rest]} = grid, :icon),
    do: %{grid | icon_name: name, icon_stack: rest}

  @doc "OSC 4: a palette color changed, or `nil` to go back to the theme's."
  def set_palette(grid, index, nil),
    do: %{grid | palette: Map.delete(grid.palette, index)} |> all_dirty()

  def set_palette(grid, index, color),
    do: %{grid | palette: Map.put(grid.palette, index, color)} |> all_dirty()

  @doc "OSC 104 with no index: the whole palette back to the theme's."
  def reset_palette(%{palette: palette} = grid) when map_size(palette) == 0, do: grid
  def reset_palette(grid), do: %{grid | palette: %{}} |> all_dirty()

  @doc "OSC 10, 11, 12: a dynamic color changed (`nil`: back to the theme's)."
  def set_dynamic_color(grid, which, color) when which in [:fg_color, :bg_color, :cursor_color],
    do: grid |> Map.put(which, color) |> all_dirty()

  @doc "A new theme, for answering programs that ask what color something is."
  def set_theme(grid, theme), do: %{grid | theme: theme}

  @doc "OSC 52: text for the clipboard."
  def set_clipboard(grid, target, text),
    do: %{grid | clipboard: text, clipboard_target: target}

  @doc "What OSC 52 asked to put on the clipboard since the last call, if anything."
  def take_clipboard(%{clipboard: nil} = grid), do: {nil, grid}

  def take_clipboard(grid),
    do: {{grid.clipboard_target, grid.clipboard}, %{grid | clipboard: nil}}

  @doc "OSC 7: the program's working directory, as a URI."
  def set_cwd_uri(grid, uri), do: %{grid | cwd_uri: uri}

  ## Hyperlinks (OSC 8)

  @doc "Text printed from now on links to `uri`, or to nothing with nil."
  def set_link(grid, nil), do: %{grid | link: nil, attrs: grid.attrs &&& bnot(@link)}
  def set_link(grid, uri), do: %{grid | link: uri, attrs: grid.attrs ||| @link}

  # Compares the cursor before and after printing: every row in between holds
  # some of the link.
  defp remember_link(grid, before, uri) do
    first = before.history + before.row
    last = grid.history + grid.row
    from = visible_col(before)
    to = visible_col(%{grid | col: max(grid.col - 1, 0), pending_at: nil})

    spans =
      for n <- first..last//1 do
        {n, if(n == first, do: from, else: 0), if(n == last, do: to, else: grid.cols - 1), uri}
      end

    %{grid | links: Enum.take(Enum.reverse(spans) ++ grid.links, @max_links)}
  end

  @doc "Where the link at row number `n`, column `col` goes, or nil."
  def link_at(grid, n, col) do
    with line when is_binary(line) <- line(grid, n),
         true <- (attrs_at(line, col) &&& @link) != 0,
         {_, _, _, uri} <-
           Enum.find(grid.links, fn {row, c1, c2, _} -> row == n and col in c1..c2 end) do
      uri
    else
      _ -> nil
    end
  end

  ## Prompts (OSC 133)

  @doc "A prompt starts on the cursor's row. The alternate screen has none."
  def mark_prompt(%{alt?: true} = grid), do: grid

  def mark_prompt(grid) do
    n = grid.history + grid.row
    marks = [n | Enum.reject(grid.prompt_marks, &(&1 == n))]
    %{grid | prompt_marks: Enum.take(marks, @max_marks)}
  end

  @doc "The row number of the closest prompt before `n` (`:older`) or after it (`:newer`)."
  def prompt_near(grid, n, :older) do
    Enum.find(grid.prompt_marks, &(&1 < n and &1 >= grid.scrollback_first))
  end

  def prompt_near(grid, n, :newer) do
    grid.prompt_marks |> Enum.reverse() |> Enum.find(&(&1 > n))
  end

  ## Mode 2026

  @doc "Whether viewers should wait: the program is in the middle of drawing."
  def set_synchronized(grid, on?), do: %{grid | synchronized: on?}

  ## Kitty keyboard flags, one stack per screen

  @doc "Flags as a program set them, keeping only what guiltty can do."
  def kitty_flags(flags), do: flags &&& 0b01011

  def push_kitty(grid, flags) do
    screen = screen(grid)
    stack = Enum.take([grid.input.kitty | grid.kitty_stack[screen]], @max_stack * 2)

    %{grid | kitty_stack: Map.put(grid.kitty_stack, screen, stack)}
    |> set_input(:kitty, kitty_flags(flags))
  end

  def pop_kitty(grid, n) do
    screen = screen(grid)
    {popped, stack} = Enum.split(grid.kitty_stack[screen], n)

    %{grid | kitty_stack: Map.put(grid.kitty_stack, screen, stack)}
    |> set_input(:kitty, List.last(popped, 0))
  end

  # 1: exactly these. 2: add them. 3: take them away.
  def set_kitty(grid, flags, mode) do
    flags = kitty_flags(flags)

    set_input(
      grid,
      :kitty,
      case mode do
        2 -> grid.input.kitty ||| flags
        3 -> grid.input.kitty &&& bnot(flags)
        _ -> flags
      end
    )
  end

  def respond(grid, bytes), do: %{grid | responses: [bytes | grid.responses]}

  ## Screens

  @doc """
  Switches to the alternate screen. With `clear: true` (mode 1049 and 1047)
  it starts blank. Nothing happens if it's already active.
  """
  def enter_alt(%{alt?: true} = grid, _opts), do: grid

  def enter_alt(grid, opts) do
    alt =
      if opts[:clear] or grid.other_lines == nil,
        do: blank_screen(grid.cols, grid.rows),
        else: grid.other_lines

    graphics =
      if opts[:clear],
        do: Graphics.clear_screen(grid.graphics, :alt, grid.rows),
        else: grid.graphics

    %{grid | other_lines: grid.lines, lines: alt, alt?: true, graphics: graphics}
    |> all_dirty()
    |> Map.put(:pending_at, nil)
  end

  @doc "Back to the main screen, exactly as it was left."
  def leave_alt(%{alt?: false} = grid), do: grid

  # The alternate screen's images go: what's left of a full-screen
  # program's pictures isn't worth the memory.
  def leave_alt(grid) do
    graphics = Graphics.clear_screen(grid.graphics, :alt, grid.rows)

    %{grid | other_lines: grid.lines, lines: grid.other_lines, alt?: false, graphics: graphics}
    |> all_dirty()
  end

  @doc "RIS: everything back to how a new grid starts, except the scrollback."
  def reset(grid) do
    keep =
      Map.take(
        grid,
        [:scrollback, :recent, :scrollback_first, :history, :scrollback_max] ++
          [:clusters, :cluster_ids, :next_cluster, :cell_pixels, :theme, :screen_reports] ++
          [:prompt_marks, :links]
      )

    grid.cols |> new(grid.rows) |> Map.merge(keep)
  end

  @doc "DECSTR: resets modes, the pen and the region, but keeps the screen."
  def soft_reset(grid) do
    %{
      grid
      | attrs: 0,
        fg: 0,
        bg: 0,
        top: 0,
        bottom: grid.rows - 1,
        left: 0,
        right: grid.cols - 1,
        margins?: false,
        lrmm: false,
        pending_at: nil,
        reverse_wrap: false,
        reverse_wrap_all: false,
        cursor_visible: true,
        autowrap: true,
        origin: false,
        insert: false,
        g0: :ascii,
        g1: :ascii,
        g2: :ascii,
        g3: :ascii,
        gl: 0,
        single_shift: nil,
        link: nil,
        synchronized: false,
        saved: Map.put(grid.saved, screen(grid), nil),
        input: @input_modes
    }
  end

  @doc """
  Changes the size. A new width rewraps the main screen and its scrollback
  (reflow): rows that wrapped join up again and split at the new width, and
  the cursor stays on the same character (see "Reflow", below).

  The alternate screen isn't rewrapped: the program there redraws itself.
  Its rows are cut or padded, and rows are added or removed at the bottom.
  When a height change alone would push the cursor off the screen, rows go
  from the top instead, so the line you're typing on stays visible. The
  scroll region and margins go back to the whole screen.

  With `at_prompt: true` the shell is waiting at its prompt, and will redraw
  it after this resize: see "The prompt", below.
  """
  def resize(grid, cols, rows, opts \\ [])
  def resize(%{cols: cols} = grid, cols, rows, _opts), do: resize_height(grid, rows)

  def resize(%{alt?: true} = grid, cols, rows, _opts) do
    drop_top = max(grid.row - (rows - 1), 0)
    alt = fit_screen(grid.lines, cols, rows, drop_top)
    main = %{grid | lines: grid.other_lines}
    {main_lines, main_cursor, main} = reflow(main, saved_main_cursor(grid), cols, rows, nil)

    %{
      resized(main, cols, rows)
      | lines: alt,
        other_lines: main_lines,
        row: min(grid.row - drop_top, rows - 1),
        col: min(grid.col, cols - 1),
        saved: restore_saved_main(grid.saved, main_cursor)
    }
    |> all_dirty()
  end

  def resize(grid, cols, rows, opts) do
    prompt_rows = if opts[:at_prompt], do: prompt_rows(grid)
    prompt_top = if prompt_rows, do: max(grid.row - prompt_rows, 0)
    {lines, {row, col}, grid} = reflow(grid, {grid.row, grid.col}, cols, rows, prompt_top)
    grid = %{grid | prompt_rows: prompt_rows}
    moved = grid.row - row

    %{resized(grid, cols, rows) | lines: lines, other_lines: nil, row: row, col: col}
    |> all_dirty()
    |> scrolled(moved)
  end

  defp resize_height(grid, rows) do
    cols = grid.cols
    drop_top = max(grid.row - (rows - 1), 0)

    # Rows that leave over the top of the main screen are scrollback, like
    # any others. On the alternate screen the program redraws.
    grid =
      if grid.alt?,
        do: grid,
        else: save_lines(grid, grid.lines |> Tuple.to_list() |> Enum.take(drop_top))

    other = if grid.other_lines, do: fit_screen(grid.other_lines, cols, rows, 0)

    %{
      resized(grid, cols, rows)
      | lines: fit_screen(grid.lines, cols, rows, drop_top),
        other_lines: other,
        row: min(grid.row - drop_top, rows - 1),
        col: min(grid.col, cols - 1)
    }
    |> all_dirty()
    |> scrolled(drop_top)
  end

  defp resized(grid, cols, rows) do
    %{
      grid
      | cols: cols,
        rows: rows,
        top: 0,
        bottom: rows - 1,
        left: 0,
        right: cols - 1,
        margins?: false,
        pending_at: nil
    }
  end

  defp saved_main_cursor(grid) do
    case grid.saved[:main] do
      %{row: row, col: col} -> {row, col}
      _ -> {0, 0}
    end
  end

  defp restore_saved_main(saved, {row, col}) do
    case saved[:main] do
      %{} = main -> Map.put(saved, :main, %{main | row: row, col: col})
      _ -> saved
    end
  end

  ## Reflow
  #
  #     old scrollback + screen           logical lines          new rows
  #     +-----------+                                            +-------+
  #     |aaaaaaaaaaa|>  (wrapped)   ->    aaaaaaaaaaaaaa    ->   |aaaaaaa|>
  #     |aaa        |                                            |aaaaaaa|
  #     |bb         |                     bb                     |bb     |
  #     +-----------+                                            +-------+
  #
  # Every row knows whether it wrapped (a bit on its last cell), so rows join
  # exactly where the text ran on, and a line that ended on its own stays
  # ended even if it was full. The last rows of the result are the new screen;
  # the rest is the new scrollback, numbered from 0 again.
  #
  # ### The prompt
  #
  # A shell waiting at its prompt redraws it on SIGWINCH: it moves up as many
  # rows as it knows the prompt took, erases to the end of the screen, and
  # prints it again. It knows nothing about reflow. Split a full-width prompt
  # row in two and it lands one row short, leaving a copy behind, at every
  # resize. So the prompt's own rows aren't rewrapped: they stay the rows the
  # shell thinks they are, cut or padded, and it redraws them a moment later.
  #
  # Where the prompt starts is an OSC 133 mark if the shell sends them.
  # Otherwise, a guess: going up from the cursor, a row belongs if it wrapped
  # (a long command) or reaches the right edge (a prompt's filler, or its right
  # side, which zsh keeps a column from the edge). A line of output just
  # above that happens to reach the edge is cut too; marks don't have that
  # problem.

  #
  # A drag is many resizes before the shell says anything, and the rows get cut
  # and padded along the way, so a guess would soon stop recognizing them. The
  # first one is kept in `prompt_rows` until the program prints something.

  @max_prompt_rows 16

  defp prompt_rows(%{prompt_rows: rows}) when rows != nil, do: rows
  defp prompt_rows(grid), do: grid.row - prompt_top(grid)

  @doc "The program printed something: what a resize knew about its prompt is out of date."
  def forget_prompt_rows(%{prompt_rows: nil} = grid), do: grid
  def forget_prompt_rows(grid), do: %{grid | prompt_rows: nil}

  defp prompt_top(%{prompt_marks: [mark | _], history: history, row: row})
       when mark >= history and mark <= history + row,
       do: mark - history

  defp prompt_top(grid), do: prompt_top(grid, grid.row, @max_prompt_rows)

  defp prompt_top(_grid, 0, _left), do: 0
  defp prompt_top(_grid, row, 0), do: row

  defp prompt_top(grid, row, left) do
    above = elem(grid.lines, row - 1)

    if row_wrapped?(above) or reaches_edge?(above, grid.cols),
      do: prompt_top(grid, row - 1, left - 1),
      else: row
  end

  defp reaches_edge?(row, cols), do: div(byte_size(trim_line(row)), @cell_size) >= cols - 1

  defp reflow(grid, cursor, cols, rows, prompt_top) do
    {older, newer} = reflow_split(grid)
    screen = reflow_screen(grid, cursor)
    {screen, prompt} = Enum.split(screen, prompt_top || length(screen))
    base = grid.scrollback_first
    start = base + length(older)

    numbered =
      (newer ++ screen) |> Enum.with_index(start) |> Enum.map(fn {row, n} -> {n, row} end)

    screen_first = grid.history

    {new_rows, total, cursor_at, positions} =
      numbered
      |> logical_lines()
      |> Enum.reduce({Enum.reverse(older), length(older), nil, %{}}, fn line, acc ->
        wrap_logical(line, cols, cursor, screen_first, acc)
      end)

    first_prompt = screen_first + length(screen)

    {new_rows, total, cursor_at, positions} =
      keep_prompt(
        prompt,
        first_prompt,
        cols,
        cursor,
        screen_first,
        {new_rows, total, cursor_at, positions}
      )

    new_rows = Enum.reverse(new_rows)
    {cursor_row, cursor_col} = cursor_at || {total, 0}
    # The newest rows fill the screen, as long as the cursor stays on it.
    top = max(max(total - rows, cursor_row - rows + 1), 0) |> min(cursor_row)
    {saved, shown} = Enum.split(new_rows, top)
    lines = shown |> Enum.take(rows) |> Enum.map(&fit_line(&1, cols))
    lines = lines ++ List.duplicate(blank_line(cols, @default_color), rows - length(lines))

    grid =
      %{
        grid
        | scrollback: %{},
          recent: [],
          scrollback_first: 0,
          history: 0,
          links: moved_links(grid.links, positions, cols),
          prompt_marks: moved_marks(grid.prompt_marks, positions, grid.scrollback_first)
      }
      |> save_lines(saved)

    # Rows saved_lines dropped because they're past scrollback_max keep their
    # numbers, and the screen's rows follow on.
    {List.to_tuple(lines), {cursor_row - top, cursor_col}, grid}
  end

  # The prompt's rows, one for one.
  defp keep_prompt(prompt, first, cols, {cursor_row, cursor_col}, screen_first, acc) do
    cursor_n = screen_first + cursor_row

    prompt
    |> Enum.with_index(first)
    |> Enum.reduce(acc, fn {row, n}, {out, at, cursor, positions} ->
      cursor = if n == cursor_n, do: {at, min(cursor_col, cols - 1)}, else: cursor
      {[row | out], at + 1, cursor, Map.put(positions, n, {at, 0, [0]})}
    end)
  end

  defp reflow_split(grid) do
    saved =
      for n <- grid.scrollback_first..(grid.history - 1)//1, do: saved_line(grid, n)

    Enum.split(saved, max(length(saved) - @reflow_rows, 0))
  end

  # The screen down to the last row that has something, or the cursor's. The
  # blank rows after it aren't text: they mustn't push text into the scrollback.
  defp reflow_screen(grid, {cursor_row, _col}) do
    rows = Tuple.to_list(grid.lines)

    last =
      rows
      |> Enum.with_index()
      |> Enum.reduce(cursor_row, fn {row, i}, last ->
        if trim_line(row) != <<>>, do: max(last, i), else: last
      end)

    Enum.take(rows, last + 1)
  end

  # [{row number, row}] into logical lines: [[{row number, row}]].
  defp logical_lines(numbered) do
    numbered
    |> Enum.chunk_while(
      [],
      fn {_n, row} = item, acc ->
        if row_wrapped?(row),
          do: {:cont, [item | acc]},
          else: {:cont, Enum.reverse([item | acc]), []}
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
  end

  defp row_wrapped?(row) when byte_size(row) < @cell_size, do: false

  defp row_wrapped?(row) do
    col = div(byte_size(row), @cell_size) - 1
    (attrs_at(row, col) &&& @wrapped) != 0
  end

  # One logical line: its rows joined, then cut at the new width.
  defp wrap_logical(
         line,
         cols,
         {cursor_row, cursor_col},
         screen_first,
         {out, first_row, cursor, positions}
       ) do
    {cells, offsets} = join_rows(line)
    cuts = cut_points(cells, cols)
    rows = wrapped_rows(cells, cuts, cols)
    out = Enum.reduce(rows, out, &[&1 | &2])

    positions =
      Enum.reduce(offsets, positions, fn {n, offset}, positions ->
        Map.put(positions, n, {first_row, offset, cuts})
      end)

    cursor_n = screen_first + cursor_row

    cursor =
      case List.keyfind(offsets, cursor_n, 0) do
        {_, offset} -> place(first_row, offset + cursor_col, cuts, cols)
        nil -> cursor
      end

    {out, first_row + length(rows), cursor, positions}
  end

  # Joined cells, and where each old row starts in them. A wide character
  # that wrapped left a blank in the last column: it isn't text, so it goes.
  defp join_rows(line) do
    {parts, offsets, _size} =
      line
      |> Enum.with_index()
      |> Enum.reduce({[], [], 0}, fn {{n, row}, i}, {parts, offsets, size} ->
        next = Enum.at(line, i + 1)
        cells = row_cells(row, next)
        {[cells | parts], [{n, size} | offsets], size + div(byte_size(cells), @cell_size)}
      end)

    {parts |> Enum.reverse() |> IO.iodata_to_binary(), Enum.reverse(offsets)}
  end

  defp row_cells(row, nil), do: trim_line(row)

  defp row_cells(row, {_n, next}) do
    last = div(byte_size(row), @cell_size) - 1
    offset = last * @cell_size
    <<before::binary-size(^offset), glyph::32, attrs::16, colors::binary-size(8)>> = row

    if glyph == ?\s and wide?(next, 0),
      do: before,
      else: <<before::binary, glyph::32, attrs &&& bnot(@wrapped)::16, colors::binary>>
  end

  # Where each new row starts, in cells. A wide character never splits.
  defp cut_points(cells, cols) do
    total = div(byte_size(cells), @cell_size)
    do_cut_points(cells, 0, total, cols, [0])
  end

  defp do_cut_points(_cells, at, total, cols, acc) when at + cols >= total, do: Enum.reverse(acc)

  defp do_cut_points(cells, at, total, cols, acc) do
    next = at + cols
    next = if spacer?(cells, next) and cols > 1, do: next - 1, else: next
    do_cut_points(cells, next, total, cols, [next | acc])
  end

  defp wrapped_rows(cells, cuts, cols) do
    total = div(byte_size(cells), @cell_size)
    ends = tl(cuts) ++ [total]

    Enum.zip(cuts, ends)
    |> Enum.map(fn {from, to} ->
      row = binary_part(cells, from * @cell_size, (to - from) * @cell_size)
      if to == total, do: row, else: wrapped_row(row, to - from, cols)
    end)
  end

  # A row that goes on in the next: full width, with the mark on its last cell.
  defp wrapped_row(row, width, cols) do
    row = row <> blank_line(cols - width, @default_color)
    offset = (cols - 1) * @cell_size + 4
    <<before::binary-size(^offset), attrs::16, after_::binary>> = row
    <<before::binary, attrs ||| @wrapped::16, after_::binary>>
  end

  # An offset into a logical line, as {new row, col}. Past the end of the
  # text (a cursor out in blank space), rows go on as they would have.
  defp place(first_row, offset, cuts, cols) do
    {i, start} =
      cuts
      |> Enum.with_index()
      |> Enum.reduce({0, 0}, fn {cut, i}, acc -> if cut <= offset, do: {i, cut}, else: acc end)

    col = offset - start

    if col > cols,
      do: {first_row + i + div(col, cols), rem(col, cols)},
      else: {first_row + i, col}
  end

  defp moved_marks(marks, positions, first) do
    marks
    |> Enum.filter(&(&1 >= first))
    |> Enum.flat_map(fn n ->
      case positions do
        %{^n => {first_row, offset, cuts}} ->
          {row, _col} = place(first_row, offset, cuts, 1_000_000)
          [row]

        _ ->
          []
      end
    end)
  end

  # A link that now wraps becomes a span on each row it's on.
  defp moved_links(links, positions, cols) do
    Enum.flat_map(links, fn {n, c1, c2, uri} ->
      case positions do
        %{^n => {first_row, offset, cuts}} ->
          {r1, n1} = place(first_row, offset + c1, cuts, cols)
          {r2, n2} = place(first_row, offset + c2, cuts, cols)

          for row <- r2..r1//-1 do
            {row, if(row == r1, do: n1, else: 0), if(row == r2, do: n2, else: cols - 1), uri}
          end

        _ ->
          []
      end
    end)
  end

  ## Helpers

  defp fit_screen(lines, cols, rows, drop_top) do
    kept =
      lines
      |> Tuple.to_list()
      |> Enum.drop(drop_top)
      |> Enum.take(rows)
      |> Enum.map(&fit_line(&1, cols))

    List.to_tuple(kept ++ List.duplicate(blank_line(cols, @default_color), rows - length(kept)))
  end

  defp fit_line(line, cols) do
    have = div(byte_size(line), @cell_size)

    if have >= cols,
      do: line |> binary_part(0, cols * @cell_size) |> fix_right(cols, cols),
      else: line <> blank_line(cols - have, @default_color)
  end

  defp blank_screen(cols, rows), do: Tuple.duplicate(blank_line(cols, @default_color), rows)
  defp blank_line(n, bg), do: :binary.copy(blank_cell(bg), n)
  defp blank_cell(bg), do: <<?\s::32, 0::16, @default_color::32, bg::32>>

  defp blank_row(grid, row), do: blank_cells(grid, row, 0, grid.cols)

  defp blank_cells(grid, _row, from, to) when from >= to, do: grid

  defp blank_cells(grid, row, from, to) do
    replace_cells(grid, row, from, :binary.copy(blank_cell(grid.bg), to - from))
  end

  defp replace_cells(grid, row, col, cells) do
    line = elem(grid.lines, row)
    start = col * @cell_size
    len = byte_size(cells)
    <<before::binary-size(^start), _::binary-size(^len), after_::binary>> = line

    line =
      <<before::binary, cells::binary, after_::binary>>
      |> fix_left(col)
      |> fix_right(col + div(len, @cell_size), grid.cols)

    %{grid | lines: put_elem(grid.lines, row, line)} |> dirty_rows(row..row)
  end

  ## Wide characters cut in half
  #
  # A wide character is a pair: a `wide` cell and its `spacer`. Overwriting,
  # inserting or deleting cells can split a pair at the edge of the cells
  # that changed. The half left behind would draw half a glyph, so it
  # becomes a blank. Only the two edges need checking.

  defp fix_left(line, 0), do: if(spacer?(line, 0), do: blank_at(line, 0), else: line)

  defp fix_left(line, col) do
    cond do
      spacer?(line, col) and not wide?(line, col - 1) -> blank_at(line, col)
      not spacer?(line, col) and wide?(line, col - 1) -> blank_at(line, col - 1)
      true -> line
    end
  end

  defp fix_right(line, col, cols) when col >= cols,
    do: if(wide?(line, cols - 1), do: blank_at(line, cols - 1), else: line)

  defp fix_right(line, col, _cols) do
    cond do
      spacer?(line, col) and not wide?(line, col - 1) -> blank_at(line, col)
      wide?(line, col - 1) and not spacer?(line, col) -> blank_at(line, col - 1)
      true -> line
    end
  end

  defp wide?(line, col), do: (attrs_at(line, col) &&& @wide) != 0
  defp spacer?(line, col), do: (attrs_at(line, col) &&& @spacer) != 0

  # A match, not binary_part + :binary.decode_unsigned: no sub-binary is
  # made and nothing is called, and it runs several times per write.
  defp attrs_at(line, col) do
    offset = col * @cell_size + 4

    case line do
      <<_::binary-size(^offset), attrs::16, _::binary>> -> attrs
      _ -> 0
    end
  end

  # Keeps the cell's background, so a colored line stays colored.
  defp blank_at(line, col) do
    offset = col * @cell_size
    <<before::binary-size(^offset), _::binary-size(10), bg::32, after_::binary>> = line
    <<before::binary, blank_cell(bg)::binary, after_::binary>>
  end

  defp all_dirty(grid), do: %{grid | dirty: :all}

  defp dirty_rows(%{dirty: :all} = grid, _rows), do: grid
  defp dirty_rows(grid, row..row//1), do: %{grid | dirty: MapSet.put(grid.dirty, row)}
  defp dirty_rows(grid, rows), do: %{grid | dirty: MapSet.union(grid.dirty, MapSet.new(rows))}

  @doc "Marks every row as changed, for a viewer that needs the whole screen."
  def mark_all_dirty(grid), do: all_dirty(grid)

  @doc "Drops images that scrolled out of the scrollback (see `Guiltty.Graphics.prune/2`)."
  def prune_graphics(%{graphics: %{placements: []}} = grid), do: grid

  def prune_graphics(grid),
    do: %{grid | graphics: Graphics.prune(grid.graphics, scrollback_size(grid))}

  @doc "What images show: see `Guiltty.Graphics.view/4`."
  def graphics_view(grid, scroll),
    do: Graphics.view(grid.graphics, screen(grid), grid.rows, if(grid.alt?, do: 0, else: scroll))

  @doc "Changes whenever what `graphics_view/2` returns may have."
  def graphics_version(grid), do: {grid.graphics.version, grid.graphics.scrolled, grid.alt?}

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)
end

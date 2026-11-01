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

  alias Guiltty.Unicode

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
    mouse_sgr: false
  }

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
    cursor_visible: true,
    # set by the program (DECSCUSR): {:block | :underline | :bar, blink?},
    # or nil for the user's choice from the config
    cursor_style: nil,
    autowrap: true,
    origin: false,
    insert: false,
    # character sets: G0 and G1 are :ascii or :dec_graphics; gl says which
    # one is in use (SO picks G1, SI picks G0)
    g0: :ascii,
    g1: :ascii,
    gl: 0,
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
    blank: nil
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

  @spec indexed(0..255) :: color()
  def indexed(n), do: 0x01_000000 ||| n

  @spec rgb(0..255, 0..255, 0..255) :: color()
  def rgb(r, g, b), do: 0x02_000000 ||| r <<< 16 ||| g <<< 8 ||| b

  def cell_size, do: @cell_size

  @doc "A blank grid. Options: `:scrollback` (rows to keep, default 10,000)."
  @spec new(pos_integer(), pos_integer(), keyword()) :: t()
  def new(cols \\ 80, rows \\ 24, opts \\ []) do
    %__MODULE__{
      cols: cols,
      rows: rows,
      bottom: rows - 1,
      lines: blank_screen(cols, rows),
      scrollback_max: Keyword.get(opts, :scrollback, 10_000)
    }
    |> all_dirty()
  end

  ## Reading

  @doc "The cursor as `{row, col}`, clamped to a visible cell."
  def cursor(grid), do: {grid.row, min(grid.col, grid.cols - 1)}

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

  ASCII takes a fast path, one byte per cell. Anything else is split into
  grapheme clusters, each taking one cell, or two if it's wide.
  """
  def print(grid, <<>>), do: grid

  def print(grid, text) do
    text = translate(text, if(grid.gl == 1, do: grid.g1, else: grid.g0))

    if ascii?(text),
      do: grid |> put_text(text) |> remember_last(binary_part(text, byte_size(text) - 1, 1)),
      else: put_clusters(grid, text)
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
    current = if grid.gl == 1, do: grid.g1, else: grid.g0

    row == rows - 1 and bottom == rows - 1 and grid.top == 0 and grid.col == 0 and
      not grid.insert and current == :ascii and
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
    style = <<grid.attrs::16, grid.fg::32, grid.bg::32>>
    cells = &for(<<c <- &1>>, into: <<>>, do: <<c::32, style::binary>>)

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
    %{grid | lines: List.to_tuple(screen)} |> all_dirty()
  end

  @doc "REP: prints the last printed character `n` more times."
  def repeat(%{last_char: nil} = grid, _n), do: grid

  def repeat(grid, n) do
    {_row, _col, text} = grid.last_char
    n = min(n, grid.cols * grid.rows)

    if ascii?(text),
      do: put_text(grid, :binary.copy(text, n)),
      else: put_graphemes(grid, List.duplicate(text, n))
  end

  # :binary.match searches in C, much faster than walking the bytes here.
  # The compiled pattern is cached in persistent_term (it can't be a module
  # attribute: it holds a reference).
  defp ascii?(text), do: :binary.match(text, high_bytes()) == :nomatch

  defp high_bytes do
    with nil <- :persistent_term.get({__MODULE__, :high_bytes}, nil) do
      pattern = :binary.compile_pattern(for b <- 0x80..0xFF, do: <<b>>)
      :persistent_term.put({__MODULE__, :high_bytes}, pattern)
      pattern
    end
  end

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
  defp put_clusters(grid, text) do
    case continued(grid, text) do
      {row, col, graphemes} -> put_graphemes(%{grid | row: row, col: col}, graphemes)
      nil -> put_graphemes(grid, String.graphemes(text))
    end
  end

  defp put_graphemes(grid, graphemes) do
    {grid, units} = intern_units(grid, graphemes)
    grid |> put_units(units) |> remember_last(List.last(graphemes))
  end

  defp continued(%{last_char: {row, col, prev}} = grid, text) do
    width = Unicode.width(prev)

    with true <- grid.row == row and grid.col == col + width,
         {glyph, _, _, _} when glyph != 0 <- cell(grid, row, col),
         true <- glyph_text(grid, glyph) == prev,
         [first | _] = graphemes when first != prev <- String.graphemes(prev <> text) do
      {row, col, graphemes}
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
    grid |> Map.put(:col, 0) |> index() |> put_units(units)
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

  ## ASCII

  defp put_text(grid, <<>>), do: grid

  defp put_text(%{col: col, cols: cols, autowrap: true} = grid, text) when col >= cols do
    grid |> Map.put(:col, 0) |> index() |> put_text(text)
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
    style = <<grid.attrs::16, grid.fg::32, grid.bg::32>>
    cells = for <<c <- chunk>>, into: <<>>, do: <<c::32, style::binary>>
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

  defp translate(text, :dec_graphics) do
    for <<c::utf8 <- text>>, into: "", do: <<Map.get(@dec_graphics, c, c)::utf8>>
  end

  def designate(grid, :g0, set), do: %{grid | g0: set}
  def designate(grid, :g1, set), do: %{grid | g1: set}
  def shift(grid, gl), do: %{grid | gl: gl}

  ## Cursor

  def carriage_return(grid), do: %{grid | col: 0}

  def backspace(grid), do: %{grid | col: max(min(grid.col, grid.cols - 1) - 1, 0)}

  def tab(grid) do
    next = (div(grid.col, @tab_width) + 1) * @tab_width
    %{grid | col: min(next, grid.cols - 1)}
  end

  @doc """
  Moves to `{row, col}`, clamped to the screen. In origin mode, rows count
  from the top of the scroll region and stay inside it.
  """
  def move_to(%{origin: true} = grid, row, col) do
    %{grid | row: clamp(grid.top + row, grid.top, grid.bottom), col: clamp(col, 0, grid.cols - 1)}
  end

  def move_to(grid, row, col) do
    %{grid | row: clamp(row, 0, grid.rows - 1), col: clamp(col, 0, grid.cols - 1)}
  end

  @doc """
  Moves by a relative amount. Vertical moves stop at the scroll region's
  edge when the cursor is inside it, and at the screen's edge otherwise.
  """
  def move_by(grid, drow, dcol) do
    {lo, hi} =
      if grid.row >= grid.top and grid.row <= grid.bottom,
        do: {grid.top, grid.bottom},
        else: {0, grid.rows - 1}

    %{
      grid
      | row: clamp(grid.row + drow, lo, hi),
        col: clamp(min(grid.col, grid.cols - 1) + dcol, 0, grid.cols - 1)
    }
  end

  @doc "The cursor's row for reports (CPR): relative to the region in origin mode."
  def report_row(%{origin: true} = grid), do: grid.row - grid.top
  def report_row(grid), do: grid.row

  def set_cursor_visible(grid, visible), do: %{grid | cursor_visible: visible}

  @doc "DECSCUSR: the cursor's shape, or nil to go back to the user's."
  def set_cursor_style(grid, style), do: %{grid | cursor_style: style}

  @doc "DECSC: saves the cursor, the pen, origin mode and the character sets."
  def save_cursor(grid) do
    saved = Map.take(grid, [:row, :col, :attrs, :fg, :bg, :origin, :g0, :g1, :gl])
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
            gl: 0
        }

      saved ->
        grid = Map.merge(grid, saved)
        %{grid | row: min(grid.row, grid.rows - 1), col: min(grid.col, grid.cols)}
    end
  end

  defp screen(%{alt?: true}), do: :alt
  defp screen(_), do: :main

  ## Scrolling

  @doc "Line feed (IND): down one row, scrolling the region up at its bottom."
  def index(%{row: row, bottom: row} = grid), do: scroll_up(grid, 1)
  def index(%{row: row, rows: rows} = grid) when row < rows - 1, do: %{grid | row: row + 1}
  def index(grid), do: grid

  @doc "Reverse index (RI): up one row, scrolling the region down at its top."
  def reverse_index(%{row: row, top: row} = grid), do: scroll_down(grid, 1)
  def reverse_index(%{row: row} = grid) when row > 0, do: %{grid | row: row - 1}
  def reverse_index(grid), do: grid

  @doc "SU: moves the region's rows up by `n`; blank rows enter at its bottom."
  def scroll_up(grid, n), do: shift_rows(grid, grid.top, grid.bottom, -n)

  @doc "SD: moves the region's rows down by `n`; blank rows enter at its top."
  def scroll_down(grid, n), do: shift_rows(grid, grid.top, grid.bottom, n)

  @doc "IL: inserts `n` blank rows at the cursor, pushing the rest of the region down."
  def insert_lines(grid, n) do
    if in_region?(grid),
      do: grid |> shift_rows(grid.row, grid.bottom, n) |> Map.put(:col, 0),
      else: grid
  end

  @doc "DL: deletes `n` rows at the cursor, pulling the rest of the region up."
  def delete_lines(grid, n) do
    if in_region?(grid),
      do: grid |> shift_rows(grid.row, grid.bottom, -n) |> Map.put(:col, 0),
      else: grid
  end

  @doc "DECSTBM: sets the scroll region (0-based, inclusive) and homes the cursor."
  def set_region(grid, top, bottom) do
    bottom = min(bottom, grid.rows - 1)

    if top < bottom,
      do: %{grid | top: top, bottom: bottom} |> move_to(0, 0),
      else: grid
  end

  defp in_region?(grid), do: grid.row >= grid.top and grid.row <= grid.bottom

  # Moves rows from..to by n (positive = down), filling with blank rows.
  # Rows pushed off the top of the whole main screen go to the scrollback.
  #
  # The usual case, a line feed at the bottom of the whole screen, is one
  # row up: tuple operations, without going through a list.
  defp shift_rows(%{rows: rows} = grid, 0, to, -1) when to == rows - 1 do
    grid = if grid.alt?, do: grid, else: save_lines(grid, [elem(grid.lines, 0)])
    {blank, grid} = cached_blank(grid)
    lines = grid.lines |> Tuple.delete_at(0) |> Tuple.insert_at(rows - 1, blank)
    %{grid | lines: lines} |> all_dirty()
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
    %{grid | lines: lines} |> dirty_rows(from..to)
  end

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

  @doc "ICH: inserts `n` blank cells at the cursor; cells pushed past the edge are lost."
  def insert_chars(grid, n) do
    col = min(grid.col, grid.cols - 1)
    n = min(n, grid.cols - col)
    keep = (grid.cols - col - n) * @cell_size
    <<_::binary-size(^col * @cell_size), tail::binary>> = elem(grid.lines, grid.row)
    moved = binary_part(tail, 0, keep)
    replace_cells(grid, grid.row, col, :binary.copy(blank_cell(grid.bg), n) <> moved)
  end

  @doc "DCH: deletes `n` cells at the cursor; blank cells enter at the right edge."
  def delete_chars(grid, n) do
    col = min(grid.col, grid.cols - 1)
    n = min(n, grid.cols - col)
    <<_::binary-size(^col * @cell_size), tail::binary>> = elem(grid.lines, grid.row)
    moved = binary_part(tail, n * @cell_size, byte_size(tail) - n * @cell_size)
    replace_cells(grid, grid.row, col, moved <> :binary.copy(blank_cell(grid.bg), n))
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

  def erase_display(grid, 2), do: Enum.reduce(0..(grid.rows - 1), grid, &blank_row(&2, &1))

  # 3: the scrollback (what `clear` sends after erasing the screen).
  def erase_display(grid, 3),
    do: %{grid | scrollback: %{}, recent: [], scrollback_first: grid.history}

  def erase_display(grid, _mode), do: grid

  @doc "EL: 0 = cursor to end of line, 1 = start to cursor, 2 = whole line."
  def erase_line(grid, 0),
    do: blank_cells(grid, grid.row, min(grid.col, grid.cols - 1), grid.cols)

  def erase_line(grid, 1), do: blank_cells(grid, grid.row, 0, min(grid.col, grid.cols - 1) + 1)
  def erase_line(grid, 2), do: blank_row(grid, grid.row)
  def erase_line(grid, _mode), do: grid

  @doc "ECH: erases `n` cells from the cursor, without moving it."
  def erase_chars(grid, n) do
    from = min(grid.col, grid.cols - 1)
    blank_cells(grid, grid.row, from, min(from + n, grid.cols))
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
        bottom: grid.rows - 1
    }
    |> all_dirty()
  end

  ## Modes and the pen

  def set_pen(grid, attrs, fg, bg), do: %{grid | attrs: attrs, fg: fg, bg: bg}

  def set_mode(grid, mode, value) when mode in [:autowrap, :insert],
    do: Map.put(grid, mode, value)

  @doc "DECOM: origin mode; switching it homes the cursor."
  def set_origin(grid, on?), do: %{grid | origin: on?} |> move_to(0, 0)

  def set_input(grid, mode, value), do: %{grid | input: Map.put(grid.input, mode, value)}

  def set_title(grid, title), do: %{grid | title: title}

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

    %{grid | other_lines: grid.lines, lines: alt, alt?: true} |> all_dirty()
  end

  @doc "Back to the main screen, exactly as it was left."
  def leave_alt(%{alt?: false} = grid), do: grid

  def leave_alt(grid) do
    %{grid | other_lines: grid.lines, lines: grid.other_lines, alt?: false} |> all_dirty()
  end

  @doc "RIS: everything back to how a new grid starts, except the scrollback."
  def reset(grid) do
    keep =
      Map.take(
        grid,
        [:scrollback, :recent, :scrollback_first, :history, :scrollback_max] ++
          [:clusters, :cluster_ids, :next_cluster]
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
        cursor_visible: true,
        autowrap: true,
        origin: false,
        insert: false,
        g0: :ascii,
        g1: :ascii,
        gl: 0,
        saved: Map.put(grid.saved, screen(grid), nil),
        input: @input_modes
    }
  end

  @doc """
  Changes the size without reflowing text: rows are cut or padded on the
  right, and rows are added or removed at the bottom. When shrinking would
  push the cursor off the screen, rows go from the top instead, so the line
  you're typing on stays visible. Both screens are resized, and the scroll
  region goes back to the whole screen.
  """
  def resize(grid, cols, rows) do
    drop_top = max(grid.row - (rows - 1), 0)
    other = if grid.other_lines, do: fit_screen(grid.other_lines, cols, rows, 0)

    %{
      grid
      | cols: cols,
        rows: rows,
        lines: fit_screen(grid.lines, cols, rows, drop_top),
        other_lines: other,
        row: min(grid.row - drop_top, rows - 1),
        col: min(grid.col, cols - 1),
        top: 0,
        bottom: rows - 1
    }
    |> all_dirty()
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

  defp attrs_at(line, col) do
    offset = col * @cell_size + 4

    if offset < byte_size(line),
      do: :binary.decode_unsigned(binary_part(line, offset, 2)),
      else: 0
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

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)
end

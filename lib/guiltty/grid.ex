defmodule Guiltty.Grid do
  @moduledoc """
  The screen as data: rows of cells, a cursor, the current *pen* (the style
  new text is written with), and the terminal's modes.

  A cell is 10 bytes, and a row is one binary of `cols` cells:

      <<char::8, attrs::8, fg::32, bg::32>>

  `attrs` holds bit flags (see the `@bold` etc. below). A color is one of:

    * `0` - the default foreground or background
    * `0x01_0000NN` - palette index `NN` (0-255)
    * `0x02_RRGGBB` - a 24-bit color

  The renderer understands the same layout, so a row goes to it unchanged.

  There are two screens. The *main* one is where the shell runs; full-screen
  programs switch to the *alternate* one and back, which brings the shell's
  screen back as it was. `lines` is always the active screen; the other one
  waits in `other_lines`.

  The cursor column may equal `cols`: the last cell was just written and the
  wrap is pending. The next printable character wraps; a CR or a cursor
  movement doesn't. xterm behaves the same way.
  """

  import Bitwise

  @cell_size 10

  # attrs bits
  @bold 0x01
  @dim 0x02
  @italic 0x04
  @underline 0x08
  @blink 0x10
  @inverse 0x20
  @hidden 0x40
  @strike 0x80

  @default_color 0

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
    last_char: nil,
    title: "",
    input: @input_modes,
    # bytes to send back to the program (answers to its queries), newest first
    responses: [],
    dirty: MapSet.new()
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

  @spec indexed(0..255) :: color()
  def indexed(n), do: 0x01_000000 ||| n

  @spec rgb(0..255, 0..255, 0..255) :: color()
  def rgb(r, g, b), do: 0x02_000000 ||| r <<< 16 ||| g <<< 8 ||| b

  def cell_size, do: @cell_size

  @spec new(pos_integer(), pos_integer()) :: t()
  def new(cols \\ 80, rows \\ 24) do
    %__MODULE__{cols: cols, rows: rows, bottom: rows - 1, lines: blank_screen(cols, rows)}
    |> all_dirty()
  end

  ## Reading

  @doc "The cursor as `{row, col}`, clamped to a visible cell."
  def cursor(grid), do: {grid.row, min(grid.col, grid.cols - 1)}

  @doc "Returns `[{row_index, row}]` for changed rows and clears the dirty set."
  def take_dirty(grid) do
    rows = grid.dirty |> Enum.sort() |> Enum.map(&{&1, elem(grid.lines, &1)})
    {rows, %{grid | dirty: MapSet.new()}}
  end

  @doc "Returns the bytes to send back to the program, oldest first, and clears them."
  def take_responses(grid), do: {Enum.reverse(grid.responses), %{grid | responses: []}}

  @doc "All rows as `[{row_index, row}]`, for a full redraw."
  def snapshot(grid), do: grid.lines |> Tuple.to_list() |> Enum.with_index(fn l, i -> {i, l} end)

  @doc "The screen as text, trailing spaces trimmed. For iex and tests."
  def dump(grid) do
    grid.lines
    |> Tuple.to_list()
    |> Enum.map_join("\n", &(&1 |> line_text() |> String.trim_trailing()))
  end

  @doc "The characters of one row."
  def line_text(line), do: for(<<c, _::binary-size(9) <- line>>, into: "", do: <<c>>)

  @doc "The cell at `{row, col}` as `{char, attrs, fg, bg}`."
  def cell(grid, row, col) do
    offset = col * @cell_size
    <<_::binary-size(^offset), c, attrs, fg::32, bg::32, _::binary>> = elem(grid.lines, row)
    {c, attrs, fg, bg}
  end

  ## Text

  @doc """
  Writes printable ASCII at the cursor with the current pen. Wraps at the
  right edge (unless autowrap is off), shifts the rest of the line right in
  insert mode, and translates through the DEC line-drawing set if it's
  active.
  """
  def print(grid, <<>>), do: grid

  def print(grid, text) do
    text = translate(text, if(grid.gl == 1, do: grid.g1, else: grid.g0))
    grid |> put_text(text) |> Map.put(:last_char, :binary.last(text))
  end

  @doc "REP: prints the last printed character `n` more times."
  def repeat(%{last_char: nil} = grid, _n), do: grid

  def repeat(grid, n),
    do: put_text(grid, :binary.copy(<<grid.last_char>>, min(n, grid.cols * grid.rows)))

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
    style = <<grid.attrs, grid.fg::32, grid.bg::32>>
    cells = for <<c <- chunk>>, into: <<>>, do: <<c, style::binary>>
    replace_cells(grid, grid.row, grid.col, cells)
  end

  # DEC Special Graphics, the line-drawing set ncurses selects with ESC ( 0.
  # Until guiltty draws Unicode (MVP 5), each piece becomes the closest
  # ASCII character, so boxes still look like boxes.
  @dec_graphics %{
    ?` => ?+,
    ?a => ?:,
    ?f => ?',
    ?g => ?#,
    ?h => ?#,
    ?i => ?#,
    ?j => ?+,
    ?k => ?+,
    ?l => ?+,
    ?m => ?+,
    ?n => ?+,
    ?o => ?-,
    ?p => ?-,
    ?q => ?-,
    ?r => ?-,
    ?s => ?_,
    ?t => ?+,
    ?u => ?+,
    ?v => ?+,
    ?w => ?+,
    ?x => ?|,
    ?y => ?<,
    ?z => ?>,
    ?{ => ?*,
    ?| => ?!,
    ?} => ?f,
    ?~ => ?.
  }

  defp translate(text, :ascii), do: text

  defp translate(text, :dec_graphics),
    do: for(<<c <- text>>, into: "", do: <<Map.get(@dec_graphics, c, c)>>)

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
  defp shift_rows(grid, from, to, n) do
    size = to - from + 1
    n = clamp(n, -size, size)
    blank = blank_line(grid.cols, grid.bg)
    {before, rest} = grid.lines |> Tuple.to_list() |> Enum.split(from)
    {region, after_} = Enum.split(rest, size)

    region =
      if n >= 0,
        do: List.duplicate(blank, n) ++ Enum.take(region, size - n),
        else: Enum.drop(region, -n) ++ List.duplicate(blank, -n)

    lines = List.to_tuple(before ++ region ++ after_)
    %{grid | lines: lines, dirty: MapSet.union(grid.dirty, MapSet.new(from..to))}
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

  @doc "ED: 0 = cursor to end, 1 = start to cursor, 2 = everything."
  def erase_display(grid, 0) do
    grid = erase_line(grid, 0)
    Enum.reduce((grid.row + 1)..(grid.rows - 1)//1, grid, &blank_row(&2, &1))
  end

  def erase_display(grid, 1) do
    grid = erase_line(grid, 1)
    Enum.reduce(0..(grid.row - 1)//1, grid, &blank_row(&2, &1))
  end

  def erase_display(grid, 2), do: Enum.reduce(0..(grid.rows - 1), grid, &blank_row(&2, &1))
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
    line = :binary.copy(<<?E, 0, 0::32, 0::32>>, grid.cols)

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

  @doc "RIS: everything back to how a new grid starts."
  def reset(grid), do: new(grid.cols, grid.rows)

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
      do: binary_part(line, 0, cols * @cell_size),
      else: line <> blank_line(cols - have, @default_color)
  end

  defp blank_screen(cols, rows), do: Tuple.duplicate(blank_line(cols, @default_color), rows)
  defp blank_line(n, bg), do: :binary.copy(blank_cell(bg), n)
  defp blank_cell(bg), do: <<?\s, 0, @default_color::32, bg::32>>

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
    line = <<before::binary, cells::binary, after_::binary>>
    %{grid | lines: put_elem(grid.lines, row, line), dirty: MapSet.put(grid.dirty, row)}
  end

  defp all_dirty(grid), do: %{grid | dirty: MapSet.new(0..(grid.rows - 1))}

  @doc "Marks every row as changed, for a viewer that needs the whole screen."
  def mark_all_dirty(grid), do: all_dirty(grid)

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)
end

defmodule Guiltty.Window.Compose do
  @moduledoc """
  One picture from a tab's panes: the renderer draws one grid, so the
  Window stitches each pane's rows into it, around one-cell separators
  (book chapter 27). Pure: the Window keeps one of these for the tab it
  shows.

      pane 1 rows  ─┐
      pane 2 rows  ─┼─> row r of the window: base row r (blanks and
      pane 3 rows  ─┘   separators), with each pane's row r - y over
                        its columns x .. x + w

  A tab of one pane is the common case, and costs nothing: its rows are
  the window's rows, as they come.

  ## Clusters

  A cell holds a codepoint, or the id of a *cluster* (a character made of
  several codepoints, like 👍🏽), which each pane's grid numbers on its
  own: two panes can both have a cluster 0x110000, meaning different
  text. With more than one pane, ids are renumbered window-wide here: the
  renderer gets each pane's clusters under new ids, and the cells that
  use them are rewritten. Only rows of panes that have clusters at all
  are rewritten.
  """

  alias Guiltty.Grid

  @cell 14
  @first_cluster 0x110000
  @max_clusters 65_536
  @default_cell {10, 20}

  # Box drawing for the separators: which neighbors are separators too
  # (up, down, left, right) picks the piece, so crossings join. In order:
  # vertical, horizontal, cross, then the T's pointing right, left, down, up.
  @shapes [
    {true, true, false, false},
    {false, false, true, true},
    {true, true, true, true},
    {true, true, false, true},
    {true, true, true, false},
    {false, true, true, true},
    {true, false, true, true}
  ]

  # Each look's pieces, in @shapes' order. Dashed lines have no T's or
  # crosses of their own: they use the solid ones of their thickness.
  @pieces %{
    {:solid, :thin} => ~c"│─┼├┤┬┴",
    {:solid, :thick} => ~c"┃━╋┣┫┳┻",
    {:dashed, :thin} => ~c"┆┄┼├┤┬┴",
    {:dashed, :thick} => ~c"┇┅╋┣┫┳┻",
    {:double, :thin} => ~c"║═╬╠╣╦╩",
    {:double, :thick} => ~c"║═╬╠╣╦╩",
    {:none, :thin} => ~c"       ",
    {:none, :thick} => ~c"       "
  }

  @default_look %{style: :solid, thickness: :thin, color: nil, active_color: nil}

  defstruct size: {0, 0},
            # visible panes, in layout order: [{id, {x, y, w, h}}]
            panes: [],
            focus: nil,
            # the window's rows with only blanks and separators
            base: {},
            # id => tuple of the pane's rows, as last sent (clusters renumbered)
            rows: %{},
            # id => its last graphics view (Guiltty.Graphics.view/4)
            graphics: %{},
            # clusters, with several panes: id => %{local => global}
            clusters: %{},
            next_cluster: @first_cluster,
            cell_pixels: nil,
            # what the separators look like (see look/2), and where they are
            look: @default_look,
            separators: []

  @type t :: %__MODULE__{}

  @doc """
  For a tab's panes (`Guiltty.Tabs` info: `rects`, `separators`, `focus`)
  in a grid of `size`. `order` is the panes in layout order: a pane too
  small to show shares a rect with another, and the first one wins.
  """
  def new(
        size,
        %{rects: rects, separators: seps, focus: focus},
        order,
        cell_pixels \\ nil,
        look \\ nil
      ) do
    panes =
      Enum.reduce(order, [], fn id, shown ->
        rect = Map.fetch!(rects, id)

        if Enum.any?(shown, fn {_, r} -> overlap?(r, rect) end),
          do: shown,
          else: [{id, rect} | shown]
      end)
      |> Enum.reverse()

    c = %__MODULE__{
      size: size,
      panes: panes,
      focus: focus,
      cell_pixels: cell_pixels,
      look: look || @default_look,
      separators: seps
    }

    %{c | base: base(c)}
  end

  @doc """
  What the separators look like, from the config: its `pane_border`
  (`style`, `thickness`) and the theme's `pane_border` and
  `pane_border_active` colors (nil: the palette's bright black and blue).
  """
  def look(pane_border, theme) do
    %{
      style: pane_border.style,
      thickness: pane_border.thickness,
      color: Map.get(theme, :pane_border),
      active_color: Map.get(theme, :pane_border_active)
    }
  end

  @doc "Draws the separators another way: every row changes."
  def restyle(c, look), do: %{c | look: look} |> then(&%{&1 | base: base(&1)})

  @doc "Whether there's more than one pane to show."
  def split?(%__MODULE__{panes: [_, _ | _]}), do: true
  def split?(_c), do: false

  @doc "The visible panes' ids."
  def ids(c), do: Enum.map(c.panes, &elem(&1, 0))

  @doc "A pane's `{x, y, w, h}`, or nil."
  def rect(c, id), do: List.keyfind(c.panes, id, 0) |> then(&(&1 && elem(&1, 1)))

  @doc """
  Takes a pane's update (`Guiltty.Session.Screen` `take_update`): its rows,
  clusters and graphics. Returns `{c, changed, clusters}`: the window rows
  that changed (`[{index, row}]`) and the clusters the renderer must learn
  (`[{id, text}]`).
  """
  def update(c, id, update) do
    case rect(c, id) do
      nil ->
        {c, [], []}

      {_x, y, w, h} ->
        {c, clusters} = clusters(c, id, Map.get(update, :clusters, []))
        stale? = update.size != {w, h}
        old = Map.get(c.rows, id, Tuple.duplicate(nil, h))

        # Rows for another size were sent before a resize reached the
        # Screen: dropped, a full update at the new size follows.
        rows =
          if stale?,
            do: old,
            else: Enum.reduce(update.rows, old, &put_row(&2, &1, c, id, h))

        c = %{c | rows: Map.put(c.rows, id, rows)}
        c = put_graphics(c, id, Map.get(update, :graphics, :same))

        changed =
          if stale?,
            do: [],
            else: for({i, _} <- update.rows, i < h, do: {y + i, compose_row(c, y + i)})

        {c, changed, clusters}
    end
  end

  defp put_row(rows, {i, row}, c, id, h) when i < h, do: put_elem(rows, i, remap(c, id, row))
  defp put_row(rows, _row, _c, _id, _h), do: rows

  @doc "Every row of the window, for a full redraw."
  def all_rows(c) do
    {_cols, rows} = c.size
    for r <- 0..(rows - 1)//1, do: {r, compose_row(c, r)}
  end

  @doc "Moves the focus: the separators around the new one light up."
  def refocus(c, focus, separators) do
    c = %{c | focus: focus, separators: separators}
    %{c | base: base(c)}
  end

  @doc "A pane's cursor, `{row, col}`, moved to where the pane is."
  def cursor(c, id, {row, col}) do
    case rect(c, id) do
      {x, y, _w, _h} -> {y + row, x + col}
      nil -> {row, col}
    end
  end

  @doc """
  What's under window cell `{col, row}`: `{:pane, id, col, row}` with the
  pane's own coordinates, or `:separator`.
  """
  def at(c, col, row) do
    Enum.find_value(c.panes, :separator, fn {id, {x, y, w, h}} ->
      if col >= x and col < x + w and row >= y and row < y + h,
        do: {:pane, id, col - x, row - y}
    end)
  end

  ## Rows

  defp compose_row(%__MODULE__{panes: [{id, {0, 0, w, _}}], size: {w, _}} = c, r),
    do: c.rows |> Map.get(id, {}) |> elem_or_nil(r) |> row_or_blank(c, r)

  defp compose_row(c, r) do
    {cols, _} = c.size
    base = elem(c.base, r)

    {parts, pos} =
      c.panes
      |> Enum.filter(fn {_id, {_x, y, _w, h}} -> r >= y and r < y + h end)
      |> Enum.sort_by(fn {_id, {x, _y, _w, _h}} -> x end)
      |> Enum.reduce({[], 0}, fn {id, {x, y, w, _h}}, {acc, pos} ->
        x = min(x, cols)
        w = min(w, cols - x)
        gap = binary_part(base, pos * @cell, (x - pos) * @cell)
        row = c.rows |> Map.get(id, {}) |> elem_or_nil(r - y)
        {[acc, gap, fit(row, base, x, w)], x + w}
      end)

    IO.iodata_to_binary([parts, binary_part(base, pos * @cell, (cols - pos) * @cell)])
  end

  defp elem_or_nil(tuple, i) when i < tuple_size(tuple), do: elem(tuple, i)
  defp elem_or_nil(_tuple, _i), do: nil

  defp row_or_blank(nil, c, r), do: elem(c.base, r)
  defp row_or_blank(row, _c, _r), do: row

  # A pane's row in its w cells: nil (not sent yet) shows the base.
  defp fit(nil, base, x, w), do: binary_part(base, x * @cell, w * @cell)
  defp fit(row, _base, _x, w) when byte_size(row) == w * @cell, do: row

  defp fit(row, base, x, w) do
    have = div(byte_size(row), @cell)

    if have > w,
      do: binary_part(row, 0, w * @cell),
      else: row <> binary_part(base, (x + have) * @cell, (w - have) * @cell)
  end

  # Blank cells and the separators: dim, except along the focused pane.
  defp base(%__MODULE__{size: {cols, rows}, look: look} = c) do
    rects = Map.new(c.panes)

    sep_cells =
      c.separators
      |> Enum.flat_map(fn
        {:vertical, x, y, h} -> for cy <- y..(y + h - 1)//1, do: {x, cy}
        {:horizontal, x, y, w} -> for cx <- x..(x + w - 1)//1, do: {cx, y}
      end)
      |> MapSet.new()

    lit = around(Map.get(rects, c.focus))
    pieces = Map.fetch!(@pieces, {look.style, look.thickness})
    colors = {color(look.color, 8), color(look.active_color, 4)}
    blank = <<?\s::32, 0::16, 0::32, 0::32>>

    lines =
      for r <- 0..(rows - 1)//1 do
        for col <- 0..(cols - 1)//1, into: <<>> do
          if MapSet.member?(sep_cells, {col, r}),
            do: separator_cell(sep_cells, col, r, MapSet.member?(lit, {col, r}), pieces, colors),
            else: blank
        end
      end

    List.to_tuple(lines)
  end

  defp separator_cell(cells, col, r, lit?, pieces, {dim, lit}) do
    has = &MapSet.member?(cells, &1)
    shape = {has.({col, r - 1}), has.({col, r + 1}), has.({col - 1, r}), has.({col + 1, r})}

    # A shape not in the list (a line's end): its vertical or horizontal.
    index =
      Enum.find_index(@shapes, &(&1 == shape)) ||
        if elem(shape, 0) or elem(shape, 1), do: 0, else: 1

    fg = if lit?, do: lit, else: dim
    <<Enum.at(pieces, index)::32, 0::16, fg::32, 0::32>>
  end

  # A theme color, or a palette entry when the theme doesn't set one.
  defp color({r, g, b}, _index), do: Grid.rgb(r, g, b)
  defp color(nil, index), do: Grid.indexed(index)

  # The ring of cells around a rect: the separators that border it.
  defp around(nil), do: MapSet.new()

  defp around({x, y, w, h}) do
    for cx <- (x - 1)..(x + w)//1,
        cy <- (y - 1)..(y + h)//1,
        cx in [x - 1, x + w] or cy in [y - 1, y + h],
        into: MapSet.new(),
        do: {cx, cy}
  end

  defp overlap?({x1, y1, w1, h1}, {x2, y2, w2, h2}),
    do: x1 < x2 + w2 and x2 < x1 + w1 and y1 < y2 + h2 and y2 < y1 + h1

  ## Clusters

  # One pane: its ids are the renderer's, as they come.
  defp clusters(%__MODULE__{panes: [_]} = c, _id, clusters), do: {c, clusters}

  defp clusters(c, id, clusters) do
    Enum.reduce(clusters, {c, []}, fn {local, text}, {c, defs} ->
      mine = Map.get(c.clusters, id, %{})

      {global, c} =
        case mine do
          %{^local => global} -> {global, c}
          _ -> allocate(c, id, local)
        end

      {c, [{global, text} | defs]}
    end)
    |> then(fn {c, defs} -> {c, Enum.reverse(defs)} end)
  end

  defp allocate(c, id, local) do
    # Past the renderer's table, start over: a cluster that's reused
    # shows its first codepoint's width of whatever was there before
    # until its pane sends it again (it does, on the next full update).
    next =
      if c.next_cluster >= @first_cluster + @max_clusters,
        do: @first_cluster,
        else: c.next_cluster

    mine = c.clusters |> Map.get(id, %{}) |> Map.put(local, next)
    {next, %{c | clusters: Map.put(c.clusters, id, mine), next_cluster: next + 1}}
  end

  defp remap(%__MODULE__{panes: [_]}, _id, row), do: row

  defp remap(c, id, row) do
    case Map.get(c.clusters, id) do
      nil ->
        row

      mine when map_size(mine) == 0 ->
        row

      mine ->
        for <<glyph::32, rest::binary-size(10) <- row>>, into: <<>> do
          if glyph >= @first_cluster,
            do: <<Map.get(mine, glyph, 0xFFFD)::32, rest::binary>>,
            else: <<glyph::32, rest::binary>>
        end
    end
  end

  ## Images

  defp put_graphics(c, _id, :same), do: c
  defp put_graphics(c, id, view), do: %{c | graphics: Map.put(c.graphics, id, view)}

  @doc """
  Every pane's images, in window cells: `{placements, images}` as the
  Window sends them. A placement is moved by its pane's place, and cut at
  its pane's edges.
  """
  def graphics(%__MODULE__{panes: [{id, {0, 0, _, _}}]} = c),
    do: Map.get(c.graphics, id, {[], %{}})

  def graphics(c) do
    {cw, ch} = c.cell_pixels || @default_cell

    Enum.reduce(c.panes, {[], %{}}, fn {id, rect}, {placements, images} ->
      {pls, imgs} = Map.get(c.graphics, id, {[], %{}})
      moved = Enum.flat_map(pls, &into_pane(&1, rect, cw, ch))
      {placements ++ moved, Map.merge(images, imgs)}
    end)
    |> then(fn {pls, imgs} -> {Enum.sort_by(pls, & &1.z), imgs} end)
  end

  # Where it's drawn, in the pane's pixels (as the renderer works it out),
  # cut to the pane, then as a placement again, in window cells.
  defp into_pane(pl, {px, py, pw, ph}, cw, ch) do
    {ox, oy} = pl.offset
    {sx, sy, sw, sh} = pl.source
    {dw, dh} = drawn(pl.cells, {sw, sh}, cw, ch)
    x0 = pl.col * cw + ox
    y0 = pl.row * ch + oy
    vx0 = max(x0, 0)
    vy0 = max(y0, 0)
    vx1 = min(x0 + dw, pw * cw)
    vy1 = min(y0 + dh, ph * ch)

    cond do
      vx1 <= vx0 or vy1 <= vy0 or sw == 0 or sh == 0 ->
        []

      vx0 == x0 and vy0 == y0 and vx1 == x0 + dw and vy1 == y0 + dh ->
        [%{pl | row: pl.row + py, col: pl.col + px}]

      true ->
        # Cut: the part of the source that lands in the pane, drawn at
        # its own size, or in whole cells when the program asked for cells.
        source = {
          sx + div((vx0 - x0) * sw, max(dw, 1)),
          sy + div((vy0 - y0) * sh, max(dh, 1)),
          max(div((vx1 - vx0) * sw, max(dw, 1)), 1),
          max(div((vy1 - vy0) * sh, max(dh, 1)), 1)
        }

        cells =
          if pl.cells == {0, 0},
            do: {0, 0},
            else: {max(round((vx1 - vx0) / cw), 1), max(round((vy1 - vy0) / ch), 1)}

        [
          %{
            pl
            | row: div(vy0, ch) + py,
              col: div(vx0, cw) + px,
              offset: {rem(vx0, cw), rem(vy0, ch)},
              source: source,
              cells: cells
          }
        ]
    end
  end

  # The renderer's sizing (main.c place_image).
  defp drawn({c, r}, _src, cw, ch) when c > 0 and r > 0, do: {c * cw, r * ch}
  defp drawn({c, 0}, {sw, sh}, cw, _ch) when c > 0, do: {c * cw, div(c * cw * sh, max(sw, 1))}
  defp drawn({0, r}, {sw, sh}, _cw, ch) when r > 0, do: {div(r * ch * sw, max(sh, 1)), r * ch}
  defp drawn(_cells, {sw, sh}, _cw, _ch), do: {sw, sh}
end

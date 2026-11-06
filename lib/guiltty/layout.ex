defmodule Guiltty.Layout do
  @moduledoc """
  How a tab is split into panes: a tree, as plain terms. Pure functions,
  no processes: `Guiltty.Tabs` keeps one per tab.

      {:pane, id}                        one pane: a session's id
      {:split, :right, ratio, a, b}      a on the left, b on the right
      {:split, :down, ratio, a, b}       a on top, b below

  `ratio` (0 to 1) is a's share of the room, the separator's cell aside.
  Splitting puts the new pane right of or below the old one, sharing its
  room half and half, as tmux and Ghostty do:

      split 1 right, then 2 down         {:split, :right, 0.5, {:pane, 1},
      +-----+-----+                        {:split, :down, 0.5, {:pane, 2},
      |     |  2  |                                           {:pane, 3}}}
      |  1  +-----+
      |     |  3  |
      +-----+-----+

  `rects/2` turns a tree into cells: where each pane is, and where the
  separators go. Every pane is at least 1 x 1 cell.
  """

  @type id :: term()
  @type t :: {:pane, id()} | {:split, :right | :down, float(), t(), t()}
  @type rect ::
          {x :: non_neg_integer(), y :: non_neg_integer(), w :: pos_integer(), h :: pos_integer()}
  @type separator ::
          {:vertical, x :: integer(), y :: integer(), h :: integer()}
          | {:horizontal, x :: integer(), y :: integer(), w :: integer()}

  @doc "One pane."
  def new(id), do: {:pane, id}

  @doc "The panes' ids, left to right and top to bottom."
  def panes({:pane, id}), do: [id]
  def panes({:split, _dir, _ratio, a, b}), do: panes(a) ++ panes(b)

  @doc "Whether `id` is one of its panes."
  def member?(tree, id), do: id in panes(tree)

  @doc "Splits pane `id`: `new_id` goes `:right` of it or `:down` (below)."
  def split({:pane, id}, id, dir, new_id) when dir in [:right, :down],
    do: {:split, dir, 0.5, {:pane, id}, {:pane, new_id}}

  def split({:pane, _} = pane, _id, _dir, _new_id), do: pane

  def split({:split, d, r, a, b}, id, dir, new_id),
    do: {:split, d, r, split(a, id, dir, new_id), split(b, id, dir, new_id)}

  @doc """
  Takes pane `id` out: the other side of its split gets all the room.
  nil when it was the last pane.
  """
  def remove({:pane, id}, id), do: nil
  def remove({:pane, _} = pane, _id), do: pane

  def remove({:split, d, r, a, b}, id) do
    case {remove(a, id), remove(b, id)} do
      {nil, b} -> b
      {a, nil} -> a
      {a, b} -> {:split, d, r, a, b}
    end
  end

  @doc """
  Where everything goes in `{x, y, w, h}` cells: `{%{id => rect},
  [separator]}`. A separator is one cell thick, between the two sides of a
  split.
  """
  def rects(tree, rect), do: place(tree, rect, %{}, [])

  defp place({:pane, id}, rect, panes, seps), do: {Map.put(panes, id, rect), seps}

  defp place({:split, :right, ratio, a, b}, {x, y, w, h}, panes, seps) do
    {wa, wb} = shares(w, ratio)

    if wb == 0 do
      place(a, {x, y, w, h}, panes, seps) |> keep_hidden(b, {x, y, w, h})
    else
      {panes, seps} = place(a, {x, y, wa, h}, panes, [{:vertical, x + wa, y, h} | seps])
      place(b, {x + wa + 1, y, wb, h}, panes, seps)
    end
  end

  defp place({:split, :down, ratio, a, b}, {x, y, w, h}, panes, seps) do
    {ha, hb} = shares(h, ratio)

    if hb == 0 do
      place(a, {x, y, w, h}, panes, seps) |> keep_hidden(b, {x, y, w, h})
    else
      {panes, seps} = place(a, {x, y, w, ha}, panes, [{:horizontal, x, y + ha, w} | seps])
      place(b, {x, y + ha + 1, w, hb}, panes, seps)
    end
  end

  # Too little room for a separator and two panes (a tiny window): the
  # second side gets a's rect too, under it, so every pane still has a
  # size; only the first shows.
  defp keep_hidden({panes, seps}, b, rect) do
    {hidden, _} = place(b, rect, %{}, [])
    {Map.merge(hidden, panes), seps}
  end

  # The room minus the separator, shared by the ratio, each side at least
  # one cell. {all, 0} when there isn't room for both.
  defp shares(size, _ratio) when size < 3, do: {size, 0}

  defp shares(size, ratio) do
    room = size - 1
    a = (room * ratio) |> round() |> max(1) |> min(room - 1)
    {a, room - a}
  end

  @doc """
  The pane next to `id` in a direction (`:left`, `:right`, `:up`,
  `:down`), from where the panes are: the nearest one that shares some of
  its edge, preferring the one that shares most. nil at the edge.
  """
  def neighbor(rects, id, direction) do
    {x, y, w, h} = Map.fetch!(rects, id)

    rects
    |> Enum.reject(fn {other, _} -> other == id end)
    |> Enum.flat_map(fn {other, {ox, oy, ow, oh}} ->
      {gap, overlap} =
        case direction do
          :left -> {x - (ox + ow), overlap(y, h, oy, oh)}
          :right -> {ox - (x + w), overlap(y, h, oy, oh)}
          :up -> {y - (oy + oh), overlap(x, w, ox, ow)}
          :down -> {oy - (y + h), overlap(x, w, ox, ow)}
        end

      if gap >= 0 and overlap > 0, do: [{gap, -overlap, other}], else: []
    end)
    |> Enum.min(fn -> nil end)
    |> case do
      nil -> nil
      {_gap, _overlap, other} -> other
    end
  end

  defp overlap(a, al, b, bl), do: max(0, min(a + al, b + bl) - max(a, b))

  @doc """
  Moves the separator nearest pane `id` that runs across `direction`, by
  `cells`: `:right` moves a vertical one right (the pane grows if it's on
  its left, shrinks if on its right), as tmux's resize-pane does. `size`
  is the whole tab's `{w, h}`, to turn cells into a ratio. Unchanged if
  there's no such separator.
  """
  def resize(tree, id, direction, cells, {w, h}) do
    {dir, sign} =
      case direction do
        :left -> {:right, -1}
        :right -> {:right, 1}
        :up -> {:down, -1}
        :down -> {:down, 1}
      end

    {tree, _moved} = nudge(tree, id, dir, sign * cells, {0, 0, w, h})
    tree
  end

  # Depth first: the deepest split of that direction around the pane is
  # the nearest separator.
  defp nudge({:pane, _} = pane, _id, _dir, _cells, _rect), do: {pane, false}

  defp nudge({:split, d, r, a, b} = split, id, dir, cells, {_x, _y, w, h} = rect) do
    if member?(split, id) do
      {ra, rb} = halves(d, r, rect)

      {a, moved} = nudge(a, id, dir, cells, ra)
      {b, moved} = if moved, do: {b, true}, else: nudge(b, id, dir, cells, rb)

      cond do
        moved ->
          {{:split, d, r, a, b}, true}

        d == dir ->
          room = if d == :right, do: w - 1, else: h - 1
          {current, _} = shares(if(d == :right, do: w, else: h), r)
          wanted = (current + cells) |> max(1) |> min(room - 1)
          {{:split, d, if(room > 1, do: wanted / room, else: r), a, b}, room > 1}

        true ->
          {{:split, d, r, a, b}, false}
      end
    else
      {split, false}
    end
  end

  defp halves(:right, r, {x, y, w, h}) do
    {wa, wb} = shares(w, r)
    {{x, y, wa, h}, {x + wa + 1, y, max(wb, 1), h}}
  end

  defp halves(:down, r, {x, y, w, h}) do
    {ha, hb} = shares(h, r)
    {{x, y, w, ha}, {x, y + ha + 1, w, max(hb, 1)}}
  end
end

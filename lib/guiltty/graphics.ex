defmodule Guiltty.Graphics do
  @moduledoc """
  Images in the terminal: what programs send with the Kitty graphics
  protocol (`ESC _ G ... ESC \\`), kept as plain terms in the grid (its
  `:graphics` field), like the text.

  Two things are kept apart:

    * an *image*: the data a program sent (raw RGB or RGBA pixels, or a
      PNG file), with its size in pixels. Nothing is decoded
      here: decoding is for the renderer, a separate OS process, so a bad
      image can only take a window down (book chapter 26);
    * a *placement*: where an image shows, anchored to a cell. It scrolls
      with the text: it remembers its row as a line number that counts
      every line the screen has scrolled since (`:scrolled`), so a line
      feed costs nothing here.

  Images stay until deleted (`a=d`) or until the screen they're on is
  cleared. Text written over one doesn't remove it: an image is under the
  cells (z < 0) or over them, not in them.

  ## What's supported of the Kitty protocol

    * actions `t` (transmit), `T` (transmit and show), `p` (show), `d`
      (delete), `q` (query)
    * formats `f=24` (RGB), `f=32` (RGBA), `f=100` (PNG), each maybe
      zlib-compressed (`o=z`), sent in chunks (`m=1`)
    * only direct transmission (`t=d`): `t=f`, `t=t` and `t=s` would make
      guiltty read a file or shared memory by name, which a program on
      the other end of ssh could use to read your files
    * placement keys `x y w h` (part of the image), `c r` (cells to fill),
      `X Y` (offset in the cell), `z`, `C` (don't move the cursor), `p`
      (placement id)

  Not supported: animation, Unicode placeholders, relative placements.
  Sixel isn't supported either: Kitty graphics covers the programs that
  draw images (yazi, chafa, timg, kitten icat).
  """

  import Bitwise

  alias Guiltty.Grid

  # One image's side, in pixels: the most every GPU can hold in a texture,
  # and the renderer's own limit.
  @max_side 4096
  # All the image data one session keeps. Past it, the oldest images go:
  # first those that don't show anywhere.
  @max_bytes 64 * 1024 * 1024
  # One image's data, decoded and inflated.
  @max_image_bytes 64 * 1024 * 1024
  # Placements one screen keeps; past it, the oldest go.
  @max_placements 256
  # Anonymous images (sent with no i= or I=) get ids from here, above any
  # id a program can give (those are 32-bit).
  @first_anonymous 1 <<< 32
  # A cell's size when no renderer has said yet (tests, a window-less
  # tab): images still cover some cells.
  @default_cell {10, 20}

  defstruct images: %{},
            placements: [],
            # a chunked Kitty transmission in progress:
            # %{control: map, data: reversed iodata, size: base64 bytes}
            upload: nil,
            bytes: 0,
            # numbers (I=) and anonymous images get ids from here
            next_id: 1,
            # lines each screen has scrolled up, while it had placements
            scrolled: %{main: 0, alt: 0},
            # changes on every change, so the Screen knows to send a view
            version: 0

  @type t :: %__MODULE__{}

  @doc "No images."
  def new, do: %__MODULE__{}

  ## Hooks the grid calls

  @doc """
  The screen scrolled `n` lines up (negative: down). Called by the grid
  only while there are placements.
  """
  def scroll(g, screen, n),
    do: bump(%{g | scrolled: Map.update!(g.scrolled, screen, &(&1 + n))})

  @doc "The screen was cleared (ED 2, entering or leaving the alternate screen)."
  def clear_screen(g, screen, rows) do
    top = g.scrolled[screen]

    drop(g, fn pl ->
      pl.screen == screen and pl.line + elem(pl.span, 1) > top and pl.line < top + rows
    end)
  end

  @doc "The scrollback was cleared (ED 3): placements above the screen go."
  def clear_scrollback(g),
    do: drop(g, fn pl -> pl.screen == :main and pl.line + elem(pl.span, 1) <= g.scrolled.main end)

  @doc """
  Placements that scrolled out of reach: above the scrollback (`kept`
  rows of it) on the main screen, above the top on the alternate one.
  """
  def prune(%{placements: []} = g, _kept), do: g

  def prune(g, kept) do
    drop(g, fn
      %{screen: :main} = pl -> pl.line + elem(pl.span, 1) <= g.scrolled.main - kept
      pl -> pl.line + elem(pl.span, 1) <= g.scrolled.alt
    end)
  end

  ## What the renderer draws

  @doc """
  What shows on the screen: `{placements, images}`. A placement is a map
  with its image's `:uid`, the `:row` (from the top of what shows; it
  can be negative, an image partly scrolled off) and `:col` of its
  top-left cell, the pixel `:offset` inside it, the `:source` rectangle
  of the image, the `:cells` it was asked to fill (`{0, 0}`: its natural
  size) and `:z`. `images` has every image they show, by uid.

  `scroll` is how far back the view is (main screen only).
  """
  def view(g, screen, rows, scroll) do
    top = g.scrolled[screen] - if(screen == :main, do: scroll, else: 0)

    placements =
      for pl <- Enum.reverse(g.placements),
          pl.screen == screen,
          row = pl.line - top,
          row + elem(pl.span, 1) > 0 and row < rows,
          image = g.images[pl.image],
          image != nil do
        %{
          uid: image.uid,
          row: row,
          col: pl.col,
          offset: pl.offset,
          source: pl.source,
          cells: pl.cells,
          z: pl.z
        }
      end
      |> Enum.sort_by(& &1.z)

    uids = MapSet.new(placements, & &1.uid)

    images =
      for {_id, image} <- g.images, MapSet.member?(uids, image.uid), into: %{} do
        {image.uid, Map.take(image, [:format, :width, :height, :data])}
      end

    {placements, images}
  end

  ## Kitty: ESC _ G control ; payload ESC \

  @doc "A Kitty graphics command, the APC string without its `G`."
  def kitty(grid, body) do
    {control, payload} =
      case :binary.split(body, ";") do
        [control, payload] -> {control, payload}
        [control] -> {control, ""}
      end

    c = parse_control(control)
    g = grid.graphics

    cond do
      # The next chunk of a transmission: only m (and q) are new. Some
      # programs repeat the first chunk's action on every chunk (kitten
      # icat sends a=T,q=2 each time); as in Kitty, that's still the
      # same image. Another action, or another image's id, starts anew.
      g.upload != nil and continues?(g.upload.control, c) ->
        continue_upload(grid, c, payload)

      c[?m] == 1 and action(c) in [?t, ?T, ?q] ->
        upload = %{control: c, data: [payload], size: byte_size(payload)}
        %{grid | graphics: %{g | upload: upload}}

      true ->
        run(%{grid | graphics: %{g | upload: nil}}, c, payload)
    end
  end

  defp continues?(first, c) do
    Map.get(c, ?a, action(first)) == action(first) and Map.get(c, ?i, first[?i]) == first[?i]
  end

  defp continue_upload(grid, c, payload) do
    %{upload: up} = g = grid.graphics
    up = %{up | data: [payload | up.data], size: up.size + byte_size(payload)}

    cond do
      # base64 is 4/3 of the data
      up.size > div(@max_image_bytes * 4, 3) + 4 ->
        g = %{g | upload: nil}
        reply(%{grid | graphics: g}, up.control, {:error, "EFBIG:image too big"})

      c[?m] == 1 ->
        %{grid | graphics: %{g | upload: up}}

      true ->
        payload = up.data |> Enum.reverse() |> IO.iodata_to_binary()
        control = if c[?q], do: Map.put(up.control, ?q, c[?q]), else: up.control
        run(%{grid | graphics: %{g | upload: nil}}, control, payload)
    end
  end

  defp action(c), do: Map.get(c, ?a, ?t)

  defp run(grid, c, payload) do
    case action(c) do
      ?q -> reply(grid, c, with({:ok, _image} <- decode(c, payload), do: :ok))
      ?t -> transmit(grid, c, payload, false)
      ?T -> transmit(grid, c, payload, true)
      ?p -> put_existing(grid, c)
      ?d -> delete(grid, c)
      _ -> reply(grid, c, {:error, "EINVAL:unsupported action"})
    end
  end

  defp transmit(grid, c, payload, show?) do
    case decode(c, payload) do
      {:ok, image} ->
        {id, c, grid} = image_id(grid, c)
        grid = store(grid, id, Map.put(image, :number, c[?I]))
        if show?, do: place(grid, c, id), else: reply(grid, c, :ok)

      {:error, _} = error ->
        reply(grid, c, error)
    end
  end

  # i= names the image; I= asks guiltty to pick an id and say it; with
  # neither, the image is anonymous (and nothing is answered).
  defp image_id(grid, c) do
    g = grid.graphics

    cond do
      (c[?i] || 0) > 0 ->
        {c[?i], c, grid}

      (c[?I] || 0) > 0 ->
        id = Enum.find(Stream.iterate(g.next_id, &(&1 + 1)), &(not Map.has_key?(g.images, &1)))
        {id, Map.put(c, ?i, id), %{grid | graphics: %{g | next_id: id + 1}}}

      true ->
        id = @first_anonymous + g.next_id
        {id, c, %{grid | graphics: %{g | next_id: g.next_id + 1}}}
    end
  end

  defp put_existing(grid, c) do
    id = c[?i] || 0

    if Map.has_key?(grid.graphics.images, id),
      do: place(grid, c, id),
      else: reply(grid, c, {:error, "ENOENT:no such image"})
  end

  defp place(grid, c, id) do
    if c[?U] == 1 do
      reply(grid, c, {:error, "EINVAL:unicode placeholders are not supported"})
    else
      image = grid.graphics.images[id]
      {row, col} = Grid.cursor(grid)
      {cw, ch} = grid.cell_pixels || @default_cell
      sx = clamp(c[?x] || 0, 0, image.width - 1)
      sy = clamp(c[?y] || 0, 0, image.height - 1)
      sw = if (c[?w] || 0) > 0, do: min(c[?w], image.width - sx), else: image.width - sx
      sh = if (c[?h] || 0) > 0, do: min(c[?h], image.height - sy), else: image.height - sy
      offset = {clamp(c[?X] || 0, 0, cw - 1), clamp(c[?Y] || 0, 0, ch - 1)}
      cells = {clamp(c[?c] || 0, 0, @max_side), clamp(c[?r] || 0, 0, @max_side)}
      span = span(cells, {sw, sh}, offset, {cw, ch})
      screen = screen(grid)
      pid = c[?p] || 0

      placement = %{
        image: id,
        pid: pid,
        screen: screen,
        line: grid.graphics.scrolled[screen] + row,
        col: col,
        offset: offset,
        source: {sx, sy, sw, sh},
        cells: cells,
        span: span,
        z: clamp(c[?z] || 0, -(1 <<< 31), (1 <<< 31) - 1)
      }

      # A placement with the same image and placement id replaces it.
      others =
        Enum.reject(grid.graphics.placements, &(pid > 0 and &1.image == id and &1.pid == pid))

      grid = %{grid | graphics: put_placements(grid.graphics, [placement | others])}
      grid = if c[?C] == 1, do: grid, else: move_past(grid, span)
      reply(grid, c, :ok)
    end
  end

  # The cells a placement covers. Asked for both: those. One of them: the
  # other keeps the picture's shape. Neither: its natural size, plus the
  # offset in the first cell.
  defp span({c, r}, _px, _offset, _cell) when c > 0 and r > 0, do: {c, r}

  defp span({c, 0}, {sw, sh}, _offset, {cw, ch}) when c > 0,
    do: {c, max(ceil_div(c * cw * sh, max(sw, 1) * ch), 1)}

  defp span({0, r}, {sw, sh}, _offset, {cw, ch}) when r > 0,
    do: {max(ceil_div(r * ch * sw, max(sh, 1) * cw), 1), r}

  defp span(_cells, {sw, sh}, {ox, oy}, {cw, ch}),
    do: {max(ceil_div(sw + ox, cw), 1), max(ceil_div(sh + oy, ch), 1)}

  # After showing an image the cursor goes where text would: past its
  # last column, on its last row (scrolling the screen if it must).
  defp move_past(grid, {cols, rows}) do
    col = grid.col
    grid = Enum.reduce(1..(rows - 1)//1, grid, fn _, g -> Grid.index(g) end)
    %{grid | col: min(col + cols, grid.cols)}
  end

  ## Deleting: a=d, d= says which

  defp delete(grid, c) do
    what = Map.get(c, ?d, ?a)
    free? = what in ?A..?Z
    {row, col} = Grid.cursor(grid)
    screen = screen(grid)
    top = grid.graphics.scrolled[screen]
    on_screen = &(&1.screen == screen)
    covers_row = &(top + &2 >= &1.line and top + &2 < &1.line + elem(&1.span, 1))
    covers_col = &(&2 >= &1.col and &2 < &1.col + elem(&1.span, 0))

    match =
      case what + if(free?, do: 32, else: 0) do
        ?a ->
          &(on_screen.(&1) and &1.line + elem(&1.span, 1) > top and
              &1.line < top + grid.rows)

        ?i ->
          &(&1.image == c[?i] and ((c[?p] || 0) == 0 or &1.pid == c[?p]))

        ?n ->
          numbered = for {id, %{number: n}} <- grid.graphics.images, n == c[?I], do: id
          &(&1.image in numbered and ((c[?p] || 0) == 0 or &1.pid == c[?p]))

        ?c ->
          &(on_screen.(&1) and covers_row.(&1, row) and covers_col.(&1, col))

        ?p ->
          &(on_screen.(&1) and covers_row.(&1, (c[?y] || 1) - 1) and
              covers_col.(&1, (c[?x] || 1) - 1))

        ?x ->
          &(on_screen.(&1) and covers_col.(&1, (c[?x] || 1) - 1))

        ?y ->
          &(on_screen.(&1) and covers_row.(&1, (c[?y] || 1) - 1))

        ?z ->
          &(on_screen.(&1) and &1.z == (c[?z] || 0))

        ?r ->
          &(&1.image >= (c[?x] || 0) and &1.image <= (c[?y] || 0))

        _ ->
          fn _ -> false end
      end

    {gone, kept} = Enum.split_with(grid.graphics.placements, match)
    g = put_placements(grid.graphics, kept)

    # Upper case also frees the images, when nothing else shows them.
    g =
      cond do
        not free? ->
          g

        what == ?I ->
          free(g, [c[?i]])

        what == ?N ->
          free(g, Enum.uniq(Enum.map(gone, & &1.image)))

        what == ?R ->
          free(g, Enum.filter(Map.keys(g.images), &(&1 in (c[?x] || 0)..(c[?y] || 0)//1)))

        true ->
          forget_unshown(g, gone)
      end

    %{grid | graphics: g}
  end

  ## Decoding what was sent

  # The image a transmission carries, checked but not decoded:
  # {:ok, %{format, width, height, data}} or {:error, "CODE:why"}.
  defp decode(c, payload) do
    with :ok <- direct(c),
         {:ok, data} <- base64(payload),
         {:ok, data} <- inflate(c[?o], data, expected_size(c)),
         {:ok, image} <- check(Map.get(c, ?f, 32), c, data) do
      {:ok, image}
    end
  end

  defp direct(c) do
    if Map.get(c, ?t, ?d) == ?d,
      do: :ok,
      else: {:error, "EINVAL:only direct transmission (t=d) is supported"}
  end

  defp base64(payload) do
    payload = for <<b <- payload>>, b not in ~c"\r\n \t", into: <<>>, do: <<b>>
    # Chunks may end without padding; :base64 wants it.
    padded = payload <> String.duplicate("=", rem(4 - rem(byte_size(payload), 4), 4))
    {:ok, :base64.decode(padded)}
  rescue
    _ -> {:error, "EINVAL:bad base64"}
  end

  defp expected_size(c) do
    case Map.get(c, ?f, 32) do
      24 -> (c[?s] || 0) * (c[?v] || 0) * 3
      32 -> (c[?s] || 0) * (c[?v] || 0) * 4
      _ -> @max_image_bytes
    end
  end

  defp inflate(nil, data, _expected), do: {:ok, data}

  # zlib-compressed (o=z): inflated a piece at a time, and stopped past
  # what the image can hold, so a small payload can't expand to gigabytes.
  defp inflate(?z, data, expected) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z)
      inflate_loop(z, :zlib.safeInflate(z, data), [], 0, min(expected, @max_image_bytes))
    rescue
      _ -> {:error, "EINVAL:bad zlib data"}
    after
      :zlib.close(z)
    end
  end

  defp inflate(_other, _data, _expected), do: {:error, "EINVAL:unknown compression"}

  defp inflate_loop(z, {status, out}, acc, size, limit) do
    size = size + IO.iodata_length(out)

    cond do
      size > limit -> {:error, "EFBIG:image too big"}
      status == :finished -> {:ok, IO.iodata_to_binary(Enum.reverse([out | acc]))}
      true -> inflate_loop(z, :zlib.safeInflate(z, []), [out | acc], size, limit)
    end
  end

  defp check(format, c, data) when format in [24, 32] do
    {w, h} = {c[?s] || 0, c[?v] || 0}

    cond do
      w not in 1..@max_side or h not in 1..@max_side ->
        {:error, "EINVAL:width and height (s, v) must be 1 to #{@max_side}"}

      byte_size(data) != w * h * div(format, 8) ->
        {:error, "ENODATA:not #{w}x#{h} pixels of data"}

      true ->
        {:ok, %{format: if(format == 24, do: :rgb, else: :rgba), width: w, height: h, data: data}}
    end
  end

  # PNG: its size is in the first chunk (IHDR), right after the signature.
  defp check(
         100,
         _c,
         <<137, ?P, ?N, ?G, 13, 10, 26, 10, _::32, "IHDR", w::32, h::32, _::binary>> = data
       ) do
    if w in 1..@max_side and h in 1..@max_side,
      do: {:ok, %{format: :png, width: w, height: h, data: data}},
      else: {:error, "EINVAL:a PNG at most #{@max_side} pixels a side"}
  end

  defp check(100, _c, _data), do: {:error, "EINVAL:not a PNG"}
  defp check(_format, _c, _data), do: {:error, "EINVAL:unsupported format"}

  ## Answers: ESC _ G i=<id>[,I=<n>][,p=<pid>];OK ESC \

  # Only when the program named the image (i= or I=), and not when q=
  # says to keep quiet: q=1 hides OKs, q=2 errors too.
  defp reply(grid, c, result) do
    i = c[?i] || 0
    n = c[?I] || 0
    q = c[?q] || 0

    quiet? =
      (i == 0 and n == 0) or (result == :ok and q >= 1) or (result != :ok and q >= 2)

    if quiet? do
      grid
    else
      keys =
        [{"i", i}, {"I", n}, {"p", c[?p] || 0}]
        |> Enum.filter(fn {_k, v} -> v > 0 end)
        |> Enum.map_join(",", fn {k, v} -> "#{k}=#{v}" end)

      message = if result == :ok, do: "OK", else: elem(result, 1)
      Grid.respond(grid, "\e_G#{keys};#{message}\e\\")
    end
  end

  # "a=T,f=32,s=10" -> %{?a => ?T, ?f => 32, ?s => 10}: numbers as
  # integers, anything else as its first character.
  defp parse_control(control) do
    control
    |> binary_part(0, min(byte_size(control), 1024))
    |> :binary.split(",", [:global])
    |> Enum.reduce(%{}, fn
      <<key, ?=, value::binary>>, acc ->
        case Integer.parse(value) do
          {n, ""} -> Map.put(acc, key, n)
          _ -> if value == "", do: acc, else: Map.put(acc, key, :binary.first(value))
        end

      _, acc ->
        acc
    end)
  end

  ## Keeping images

  defp store(grid, id, image) do
    g = grid.graphics
    old = g.images[id]
    image = Map.put(image, :uid, unique())
    bytes = g.bytes + byte_size(image.data) - if(old, do: byte_size(old.data), else: 0)
    g = bump(%{g | images: Map.put(g.images, id, image), bytes: bytes})
    %{grid | graphics: evict(g, id)}
  end

  # Over the limit: the oldest images go, first those that show nowhere,
  # then the others with their placements. Never the one just stored.
  defp evict(%{bytes: bytes} = g, _keep) when bytes <= @max_bytes, do: g

  defp evict(g, keep) do
    shown = MapSet.new(g.placements, & &1.image)

    victim =
      g.images
      |> Enum.reject(fn {id, _} -> id == keep end)
      |> Enum.sort_by(fn {id, image} -> {MapSet.member?(shown, id), image.uid} end)
      |> List.first()

    case victim do
      nil -> g
      {id, _} -> g |> free([id]) |> evict(keep)
    end
  end

  # Drops images and their placements.
  defp free(g, ids) do
    ids = Enum.filter(ids, &Map.has_key?(g.images, &1))
    gone = Enum.reduce(ids, 0, &(byte_size(g.images[&1].data) + &2))
    placements = Enum.reject(g.placements, &(&1.image in ids))

    %{g | images: Map.drop(g.images, ids), bytes: g.bytes - gone}
    |> put_placements(placements)
  end

  # Anonymous images can't be shown again: once their placements are
  # gone, so are they.
  defp forget_unshown(g, gone) do
    shown = MapSet.new(g.placements, & &1.image)

    ids =
      for pl <- gone,
          pl.image >= @first_anonymous,
          not MapSet.member?(shown, pl.image),
          uniq: true,
          do: pl.image

    free(g, ids)
  end

  defp drop(g, fun) do
    {gone, kept} = Enum.split_with(g.placements, fun)
    if gone == [], do: g, else: g |> put_placements(kept) |> forget_unshown(gone)
  end

  defp put_placements(g, placements),
    do: bump(%{g | placements: Enum.take(placements, @max_placements)})

  defp bump(g), do: %{g | version: g.version + 1}

  defp screen(%{alt?: true}), do: :alt
  defp screen(_grid), do: :main

  defp unique, do: System.unique_integer([:positive, :monotonic])
  defp ceil_div(a, b), do: div(a + b - 1, b)
  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)
end

defmodule Guiltty.RendererReplayTest do
  # The renderers on their own, no Elixir: each replays a recorded session
  # (test/fixtures/replay/session.msgs, the port messages a Window sent) on
  # SDL's offscreen driver and saves the last frame. Both run their debug
  # builds: sanitizers, and for Vulkan the validation layers.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @fixture Path.expand("../fixtures/replay/session.msgs", __DIR__)
  @env [
    {"SDL_VIDEO_DRIVER", "offscreen"},
    {"ASAN_OPTIONS", "detect_leaks=0"},
    {"UBSAN_OPTIONS", "halt_on_error=1:print_stacktrace=1"}
  ]

  defp replay(renderer, dir, fixture \\ @fixture) do
    out = Path.join(dir, "#{renderer}-#{Path.basename(fixture)}.ppm")
    bin = Path.join(:code.priv_dir(:guiltty), renderer)

    {log, status} =
      System.cmd(bin, ["--replay", fixture, "--screenshot", out],
        env: @env,
        stderr_to_stdout: true
      )

    assert status == 0, "#{renderer} exited #{status}:\n#{log}"
    refute log =~ "validation", log
    refute log =~ "Sanitizer", log
    ppm(File.read!(out))
  end

  # A binary PPM: "P6\nW H\n255\n" and then RGB bytes.
  defp ppm(data) do
    [magic, size, "255", pixels] = String.split(data, "\n", parts: 4)
    assert magic == "P6"
    [w, h] = size |> String.split() |> Enum.map(&String.to_integer/1)
    assert byte_size(pixels) == w * h * 3
    {w, h, pixels}
  end

  test "OpenGL replays the session", %{tmp_dir: dir} do
    {w, h, pixels} = replay("guiltty_gl-dbg", dir)
    assert w > 0 and h > 0
    # Not one flat color: text was drawn.
    assert pixels |> :binary.bin_to_list() |> Enum.chunk_every(3) |> Enum.uniq() |> length() > 10
  end

  @tag :vulkan
  test "Vulkan draws the same picture as OpenGL", %{tmp_dir: dir} do
    {w, h, gl} = replay("guiltty_gl-dbg", dir)
    {^w, ^h, vk} = replay("guiltty_vk-dbg", dir)

    # The two can round a blend differently: allow a little per channel,
    # and a few odd pixels.
    differ =
      Enum.zip(chunks(gl), chunks(vk))
      |> Enum.count(fn {a, b} -> Enum.zip_with(a, b, &abs(&1 - &2)) |> Enum.max() > 8 end)

    assert differ <= div(w * h, 1000), "#{differ} of #{w * h} pixels differ"
  end

  # Damage tracking: the renderers keep last frame's cells on the GPU (in
  # Vulkan, one copy per frame in flight) and upload only the rows that
  # changed. Many small updates must end on exactly the picture one whole
  # update gives; a row left behind would show.
  defp damage_msgs(dir) do
    alias Guiltty.{Grid, Parser, Terminal, Theme}
    alias Guiltty.Window.Protocol

    options = %{padding: 6, opacity: 1.0, bold_is_bright: true}
    setup = Protocol.setup(20, 8, Theme.default(), %{family: "monospace", size: 16}, options)

    steps =
      for n <- 1..30 do
        case rem(n, 3) do
          0 -> "\e[#{rem(n, 8) + 1};#{rem(n * 7, 15) + 1}H\e[3#{rem(n, 7) + 1}mx#{n}\e[0m"
          1 -> "\e[8;1H\nline #{n}"
          2 -> "\e[#{rem(n * 3, 8) + 1};1H\e[2Krow #{n}"
        end
      end

    update = fn grid ->
      {rows, grid} = Grid.take_dirty(grid)

      msg =
        Protocol.rows(%{
          size: {20, 8},
          rows: rows,
          cursor: Grid.cursor(grid),
          cursor_visible: true
        })

      {msg, grid}
    end

    {first, grid} = update.(Grid.new(20, 8))

    {msgs, grid} =
      Enum.map_reduce(steps, grid, fn bytes, grid ->
        {_p, commands} = Parser.feed(Parser.new(), bytes)
        update.(Terminal.apply(grid, commands))
      end)

    whole =
      Protocol.rows(%{
        size: {20, 8},
        rows: Grid.snapshot(grid),
        cursor: Grid.cursor(grid),
        cursor_visible: true
      })

    write = fn name, messages ->
      path = Path.join(dir, name)
      File.write!(path, Enum.map(messages, &[<<IO.iodata_length(&1)::32>>, &1]))
      path
    end

    {write.("steps.msgs", [setup, first | msgs]), write.("final.msgs", [setup, whole])}
  end

  test "OpenGL: many small updates end on the picture of one whole one", %{tmp_dir: dir} do
    {steps, final} = damage_msgs(dir)
    assert replay("guiltty_gl-dbg", dir, steps) == replay("guiltty_gl-dbg", dir, final)
  end

  @tag :vulkan
  test "Vulkan: many small updates end on the picture of one whole one", %{tmp_dir: dir} do
    {steps, final} = damage_msgs(dir)
    assert replay("guiltty_vk-dbg", dir, steps) == replay("guiltty_vk-dbg", dir, final)
  end

  # The fuzz seeds, and any crash the fuzzer found, saved next to them
  # (test/fixtures/fuzz/messages/, see book chapter 20): the real
  # renderer must get through each one with no sanitizer report. It may
  # refuse a message and exit, but never crash.
  test "the fuzz inputs replay without a sanitizer report", %{tmp_dir: dir} do
    bin = Path.join(:code.priv_dir(:guiltty), "guiltty_gl-dbg")

    for input <- Path.wildcard(Path.expand("../fixtures/fuzz/messages/*", __DIR__)) do
      out = Path.join(dir, "fuzz.ppm")

      {log, status} =
        System.cmd(bin, ["--replay", input, "--screenshot", out],
          env: @env,
          stderr_to_stdout: true
        )

      refute log =~ "Sanitizer", "#{input}:\n#{log}"
      assert status < 128, "#{input} killed by signal #{status - 128}:\n#{log}"
    end
  end

  ## Images (book chapter 26)
  #
  # A solid red image, sent the way a Window sends one, in each format the
  # renderer decodes. What's checked is where the red lands in the
  # screenshot: its exact size in pixels, and its place.

  @red_w 30
  @red_h 40

  defp red_image(:rgb), do: %{format: :rgb, data: :binary.copy(<<255, 0, 0>>, @red_w * @red_h)}

  defp red_image(:rgba),
    do: %{format: :rgba, data: :binary.copy(<<255, 0, 0, 255>>, @red_w * @red_h)}

  defp red_image(:png), do: %{format: :png, data: png(@red_w, @red_h, <<255, 0, 0>>)}

  # The smallest honest PNG: a signature, IHDR (8-bit RGB), one IDAT with
  # every row behind a 0 (no filter) byte, IEND. Each chunk has its CRC.
  defp png(w, h, rgb) do
    chunk = fn type, data ->
      [<<byte_size(data)::32>>, type, data, <<:erlang.crc32([type, data])::32>>]
    end

    rows = for _ <- 1..h, into: <<>>, do: <<0>> <> :binary.copy(rgb, w)

    IO.iodata_to_binary([
      <<137, ?P, ?N, ?G, 13, 10, 26, 10>>,
      chunk.("IHDR", <<w::32, h::32, 8, 2, 0, 0, 0>>),
      chunk.("IDAT", :zlib.compress(rows)),
      chunk.("IEND", <<>>)
    ])
  end

  defp image_msgs(dir, name, image, placement) do
    alias Guiltty.{Grid, Theme}
    alias Guiltty.Window.Protocol

    options = %{padding: 6, opacity: 1.0, bold_is_bright: true}
    grid = Grid.new(20, 8)

    placement =
      Map.merge(
        %{
          uid: 7,
          row: 0,
          col: 0,
          offset: {0, 0},
          source: {0, 0, @red_w, @red_h},
          cells: {0, 0},
          z: 0
        },
        placement
      )

    messages = [
      Protocol.setup(20, 8, Theme.default(), %{family: "monospace", size: 16}, options),
      Protocol.image(7, Map.merge(%{width: @red_w, height: @red_h}, image)),
      Protocol.placements({20, 8}, [placement]),
      Protocol.rows(%{
        size: {20, 8},
        rows: Grid.snapshot(grid),
        cursor: {0, 0},
        cursor_visible: false
      })
    ]

    path = Path.join(dir, "#{name}.msgs")

    File.write!(
      path,
      Enum.map(messages, fn m ->
        bin = IO.iodata_to_binary(m)
        [<<byte_size(bin)::32>>, bin]
      end)
    )

    path
  end

  # The box around the red pixels: {x, y, w, h}, or nil.
  defp red_box({w, _h, pixels}) do
    red =
      for {[r, g, b], i} <-
            pixels |> :binary.bin_to_list() |> Enum.chunk_every(3) |> Enum.with_index(),
          r > 200 and g < 60 and b < 60,
          do: {rem(i, w), div(i, w)}

    if red != [] do
      {xs, ys} = Enum.unzip(red)

      {Enum.min(xs), Enum.min(ys), Enum.max(xs) - Enum.min(xs) + 1,
       Enum.max(ys) - Enum.min(ys) + 1}
    end
  end

  for renderer <- ["guiltty_gl-dbg", "guiltty_vk-dbg"], format <- [:rgb, :rgba, :png] do
    @tag if(renderer =~ "vk", do: :vulkan, else: :gl)
    test "#{renderer} draws a #{format} image at its own size, where it's placed", %{tmp_dir: dir} do
      at_top = image_msgs(dir, "top", red_image(unquote(format)), %{})
      lower = image_msgs(dir, "lower", red_image(unquote(format)), %{row: 2, col: 3})
      {x0, y0, w, h} = red_box(replay(unquote(renderer), dir, at_top))
      assert {w, h} == {@red_w, @red_h}

      # Two rows down, three columns right: cell sizes, whatever the font.
      {x1, y1, ^w, ^h} = red_box(replay(unquote(renderer), dir, lower))
      assert rem(x1 - x0, 3) == 0 and rem(y1 - y0, 2) == 0
      assert x1 > x0 and y1 > y0
    end
  end

  @tag :gl
  test "an image partly scrolled off is cut at the grid's top, not drawn over the tab bar",
       %{tmp_dir: dir} do
    {_x, top, _w, _h} =
      red_box(replay("guiltty_gl-dbg", dir, image_msgs(dir, "a", red_image(:rgba), %{})))

    # The grid's first row starts one cell below the padding (the tab bar).
    cell_h = top - 6
    up = image_msgs(dir, "b", red_image(:rgba), %{row: -1})
    assert {_x, ^top, @red_w, h} = red_box(replay("guiltty_gl-dbg", dir, up))
    assert h == @red_h - cell_h
  end

  @tag :gl
  test "asked for a number of cells, an image is scaled to fill them", %{tmp_dir: dir} do
    {_x, top, _w, _h} =
      red_box(replay("guiltty_gl-dbg", dir, image_msgs(dir, "a", red_image(:rgba), %{})))

    cell_h = top - 6
    msgs = image_msgs(dir, "c", red_image(:rgba), %{cells: {0, 3}})
    {_x, _y, w, h} = red_box(replay("guiltty_gl-dbg", dir, msgs))
    assert h == 3 * cell_h
    # Only the rows were asked for: the width keeps the picture's shape.
    assert_in_delta w, h * @red_w / @red_h, 1.5
  end

  ## The password lock (book chapter 1)
  #
  # "Password: " with the cursor after it. Read with echo off, a lock
  # shows there instead of the block: some of the cell in the cursor's
  # color (the lock), not all of it (the block), and nothing else moves.

  defp lock_msgs(dir, name, secret) do
    alias Guiltty.{Grid, Parser, Terminal, Theme}
    alias Guiltty.Window.Protocol

    {_parser, commands} = Parser.feed(Parser.new(), "Password: ")
    grid = Terminal.apply(Grid.new(20, 3), commands)
    options = %{padding: 6, opacity: 1.0, bold_is_bright: true}

    messages = [
      Protocol.setup(20, 3, Theme.default(), %{family: "monospace", size: 20}, options),
      Protocol.rows(%{
        size: {20, 3},
        rows: Grid.snapshot(grid),
        cursor: Grid.cursor(grid),
        cursor_visible: true,
        cursor_secret: secret
      })
    ]

    path = Path.join(dir, "#{name}.msgs")

    File.write!(
      path,
      Enum.map(messages, fn m ->
        bin = IO.iodata_to_binary(m)
        [<<byte_size(bin)::32>>, bin]
      end)
    )

    path
  end

  defp cursor_pixels({_w, _h, pixels}) do
    {r, g, b} = Guiltty.Theme.default().cursor

    pixels
    |> :binary.bin_to_list()
    |> Enum.chunk_every(3)
    |> Enum.count(fn [pr, pg, pb] -> abs(pr - r) + abs(pg - g) + abs(pb - b) < 12 end)
  end

  for renderer <- ["guiltty_gl-dbg", "guiltty_vk-dbg"] do
    @tag if(renderer =~ "vk", do: :vulkan, else: :gl)
    test "#{renderer} draws a lock instead of the cursor while a password is read",
         %{tmp_dir: dir} do
      block = cursor_pixels(replay(unquote(renderer), dir, lock_msgs(dir, "block", false)))
      lock = cursor_pixels(replay(unquote(renderer), dir, lock_msgs(dir, "lock", true)))
      # The lock covers a good part of the cell, never all of it.
      assert lock > block / 5 and lock < block * 3 / 4, "lock #{lock}, block #{block}"
    end
  end

  # Ligatures need a font that has them; JetBrains Mono does (its "NL"
  # builds don't). The messages are made here, as a Window would send them.
  @tag :ligature_font
  test "ligatures join -> and != when the setting is on", %{tmp_dir: dir} do
    on = ligature_msgs(dir, "on", true)
    off = ligature_msgs(dir, "off", false)
    {w, h, joined} = replay("guiltty_gl-dbg", dir, on)
    {^w, ^h, plain} = replay("guiltty_gl-dbg", dir, off)
    assert joined != plain
  end

  @tag :ligature_font
  test "text without ligatures draws the same either way", %{tmp_dir: dir} do
    on = ligature_msgs(dir, "on", true, "plain text, (no) [ligatures] here.")
    off = ligature_msgs(dir, "off", false, "plain text, (no) [ligatures] here.")
    assert replay("guiltty_gl-dbg", dir, on) == replay("guiltty_gl-dbg", dir, off)
  end

  defp ligature_msgs(dir, name, ligatures, text \\ "x |> f() -> y != z => w") do
    alias Guiltty.{Grid, Parser, Terminal, Theme}
    alias Guiltty.Window.Protocol

    {_parser, commands} = Parser.feed(Parser.new(), text)
    grid = Terminal.apply(Grid.new(40, 3), commands)
    options = %{padding: 6, opacity: 1.0, bold_is_bright: true, ligatures: ligatures}

    messages = [
      Protocol.setup(40, 3, Theme.default(), %{family: ligature_font(), size: 20}, options),
      Protocol.rows(%{
        size: {40, 3},
        rows: Grid.snapshot(grid),
        cursor: Grid.cursor(grid),
        cursor_visible: false
      })
    ]

    path = Path.join(dir, "#{name}.msgs")

    File.write!(
      path,
      Enum.map(messages, fn m ->
        bin = IO.iodata_to_binary(m)
        [<<byte_size(bin)::32>>, bin]
      end)
    )

    path
  end

  def ligature_font do
    {families, 0} = System.cmd("fc-list", [":", "family"])

    families
    |> String.split(["\n", ","])
    |> Enum.find(&(&1 =~ ~r/^JetBrains ?Mono( Nerd Font Mono)?$/))
  end

  defp chunks(pixels), do: pixels |> :binary.bin_to_list() |> Enum.chunk_every(3)
end

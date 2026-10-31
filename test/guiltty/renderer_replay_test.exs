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

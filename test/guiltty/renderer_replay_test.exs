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

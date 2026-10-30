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

  defp replay(renderer, dir) do
    out = Path.join(dir, "#{renderer}.ppm")
    bin = Path.join(:code.priv_dir(:guiltty), renderer)

    {log, status} =
      System.cmd(bin, ["--replay", @fixture, "--screenshot", out],
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

  defp chunks(pixels), do: pixels |> :binary.bin_to_list() |> Enum.chunk_every(3)
end

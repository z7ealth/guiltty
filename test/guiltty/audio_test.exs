defmodule Guiltty.AudioTest do
  # Listeners register in the application's Guiltty.PubSub: not async,
  # so another test's levels never reach this one.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Guiltty.Audio

  @moduletag :tmp_dir

  setup do
    :ok = Audio.listen()
  end

  # One second of a sine wave at `hz`, as guiltty_audio records sound:
  # 32-bit floats, stereo, 48 kHz.
  defp sine(dir, hz) do
    path = Path.join(dir, "#{hz}.raw")

    samples =
      for i <- 0..47_999, into: <<>> do
        s = 0.5 * :math.sin(2 * :math.pi() * hz * i / 48_000)
        <<s::float-32-little, s::float-32-little>>
      end

    File.write!(path, samples)
    path
  end

  # The band with the loudest level in the last LEVELS before the file ends.
  defp loudest_band(path) do
    capture_log(fn ->
      start_supervised!({Audio, name: nil, enabled: true, args: ["--raw", path]})
      send(self(), {:levels, collect([])})
      stop_supervised!(Audio)
    end)

    # Stopping may say "nothing to show" once more: not for the next run.
    receive do
      {:audio, <<>>} -> :ok
    after
      0 -> :ok
    end

    assert_received {:levels, [_ | _] = all}
    levels = :binary.bin_to_list(List.last(all))
    assert length(levels) == 16
    Enum.find_index(levels, &(&1 == Enum.max(levels)))
  end

  # Every {:audio, levels} until the helper ends (an empty one).
  defp collect(acc) do
    receive do
      {:audio, <<>>} -> Enum.reverse(acc)
      {:audio, levels} -> collect([levels | acc])
    after
      5_000 -> flunk("no end of the levels")
    end
  end

  test "a tone lights the band it's in", %{tmp_dir: dir} do
    # 16 bands from 50 Hz to 16 kHz, about half an octave each: 1 kHz is
    # in band 8 (894 to 1283 Hz), 100 Hz in band 1 (72 to 103), 8 kHz in
    # band 14 (7780 to 11157).
    assert loudest_band(sine(dir, 1000)) == 8
    assert loudest_band(sine(dir, 100)) == 1
    assert loudest_band(sine(dir, 8000)) == 14
  end

  test "silence sends the bars at rest, and nothing more", %{tmp_dir: dir} do
    path = Path.join(dir, "silence.raw")
    File.write!(path, :binary.copy(<<0>>, 8 * 48_000))
    silent = :binary.copy(<<0>>, 16)

    capture_log(fn ->
      start_supervised!({Audio, name: nil, enabled: true, args: ["--raw", path]})
      # As soon as the helper runs, 16 bars at 0: their room in the tab
      # bar is kept while the visualizer is on, sound or not.
      assert_receive {:audio, ^silent}, 5_000
      # The helper ends with the file: then the empty message, no bars.
      assert_receive {:audio, <<>>}, 5_000
    end)

    refute_received {:audio, _}
  end

  test "a window that listens later is told the bars at once" do
    silent = :binary.copy(<<0>>, 16)
    test = self()
    # As if the helper were running and had sent the bars at rest.
    pid = start_supervised!({Audio, enabled: false})
    :sys.replace_state(pid, &%{&1 | levels: silent})

    spawn_link(fn ->
      Audio.listen()
      receive do: (msg -> send(test, {:late, msg}))
    end)

    assert_receive {:late, {:audio, ^silent}}, 1_000
  end

  test "listening twice is listening once" do
    :ok = Audio.listen()
    assert Registry.keys(Guiltty.PubSub, self()) == [:audio]
  end

  test "off sends nothing, and starts nothing" do
    pid = start_supervised!({Audio, name: nil, enabled: false})
    assert %{port: nil} = :sys.get_state(pid)
    refute_receive {:audio, _}, 100
  end
end

defmodule Guiltty.WatchdogTest do
  # The system monitor is one per node: not async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  test "a process with a big heap is named in a warning, once" do
    start_supervised!({Guiltty.Watchdog, large_heap_mb: 8})

    log =
      capture_log(fn ->
        {pid, ref} =
          spawn_monitor(fn ->
            Process.register(self(), :watchdog_big)
            # About 16 MB of heap, collected twice: two reports, one warning.
            big = Enum.to_list(1..1_000_000)
            :erlang.garbage_collect()
            :erlang.garbage_collect()
            length(big)
          end)

        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
        Process.sleep(100)
      end)

    assert log =~ "watchdog: :watchdog_big has a"
    assert length(String.split(log, "watchdog:")) == 2
  end
end

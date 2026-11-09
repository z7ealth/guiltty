# Hours of use in minutes: a real session under a flood of mixed output, resized
# all the while. A terminal that's going to run for weeks mustn't grow. Prints
# what the VM and the session use as it goes; a healthy run levels off.
#
#   mix run --no-start bench/soak.exs [seconds]        (default 120)

{:ok, _} = Registry.start_link(keys: :unique, name: Guiltty.Registry)
alias Guiltty.Session

seconds =
  case System.argv() do
    [n | _] -> String.to_integer(n)
    _ -> 120
  end

# Scrolling text, colors, wide characters, links, titles, the alternate screen,
# colors changing, tab stops, margins: a bit of everything this release added.
script = ~S"""
i=0
while :; do
  i=$((i + 1))
  seq 1 200
  printf '\033[31mred \033[1;4mbold\033[m 日本語 🇯🇵 \033]8;;https://x.y/%d\alink\033]8;;\a\n' "$i"
  printf '\033]2;title %d\a\033[22;0t\033[23;0t\033]133;A\a' "$i"
  printf '\033]4;1;rgb:%02x/00/00\033\\\033]104\033\\' $((i % 256))
  printf '\033[?1049h\033[Halt screen %d\033[?1049l' "$i"
  printf '\033[?69h\033[2;20s\033[3;1Hx\033[?69l'
  printf '\033H\033[3g\033[?2026hsync\033[?2026l\n'
  printf '%0200d\n' "$i"
done
"""

{:ok, sup} =
  Session.Supervisor.start_link(
    id: :soak,
    shell: "/bin/sh",
    args: ["-c", script],
    cols: 80,
    rows: 24,
    scrollback: 10_000
  )

Process.unlink(sup)
started = System.monotonic_time(:second)

screen_mb = fn ->
  pid = GenServer.whereis(Session.via(:soak, :screen))
  {:memory, bytes} = Process.info(pid, :memory)
  {:binary, binaries} = Process.info(pid, :binary)
  shared = binaries |> Enum.uniq_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)) |> Enum.sum()
  (bytes + shared) / 1_048_576
end

report = fn elapsed ->
  total = :erlang.memory(:total) / 1_048_576

  IO.puts(
    "#{String.pad_leading(to_string(elapsed), 5)} s  VM #{:erlang.float_to_binary(total, decimals: 1)} MB" <>
      "  screen #{:erlang.float_to_binary(screen_mb.(), decimals: 1)} MB"
  )
end

widths = Stream.cycle([40, 120, 80, 33, 200, 80])

widths
|> Stream.with_index()
|> Enum.reduce_while(nil, fn {cols, i}, _ ->
  elapsed = System.monotonic_time(:second) - started

  if elapsed >= seconds do
    {:halt, nil}
  else
    :ok = Session.resize(:soak, cols, 24 + rem(i, 3))
    if rem(i, 20) == 0, do: report.(elapsed)
    Process.sleep(500)
    {:cont, nil}
  end
end)

report.(System.monotonic_time(:second) - started)
IO.puts("session alive: #{Process.alive?(sup)}")

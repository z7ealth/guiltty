# How fast the Elixir side digests what programs print: the parser and the
# grid (Guiltty.Parser, Guiltty.Terminal), with no processes, no PTY and no
# renderer. Each stream is made here, so the numbers don't depend on what's
# on the machine. Book chapter 22.
#
#   mix run --no-start bench/throughput.exs        (or: make bench)
alias Guiltty.{Grid, Parser, Terminal}

cols = 120
rows = 40

streams = [
  # Short lines, so the screen scrolls on nearly every one: `seq`, logs.
  {"scrolling", for(n <- 1..150_000, into: "", do: "#{n}\r\n")},
  # Long lines with a color change every word: `ls --color`, compilers.
  {"colors",
   for n <- 1..8_000, into: "" do
     words = for w <- 1..12, do: "\e[#{31 + rem(n + w, 7)}mword#{w}\e[0m"
     Enum.join(words, " ") <> "\r\n"
   end},
  # Wide characters and emoji: what Unicode costs.
  {"unicode", String.duplicate("日本語のテキスト 👍🏽 ünïcödé é ", 6_000) <> "\r\n"},
  # A full-screen program redrawing: cursor moves, then a row each (htop).
  {"full screen",
   for frame <- 1..300, into: "" do
     for row <- 1..rows, into: "\e[H" do
       "\e[#{row};1H\e[7m#{String.pad_trailing("row #{row} frame #{frame}", cols)}\e[0m"
     end
   end}
]

# Programs' output arrives in reads of up to 64 KB (the Pty's chunk size).
run = fn bytes ->
  chunks = for <<c::binary-size(65_536) <- bytes>>, do: c
  rest = binary_part(bytes, length(chunks) * 65_536, rem(byte_size(bytes), 65_536))

  Enum.reduce(chunks ++ [rest], {Parser.new(), Grid.new(cols, rows)}, fn chunk, {p, g} ->
    {p, cmds} = Parser.feed(p, chunk)
    {p, Terminal.apply(g, cmds)}
  end)
end

IO.puts("parser + grid, #{cols}x#{rows}, best of 3:")

for {name, bytes} <- streams do
  run.(bytes)
  us = Enum.min(for _ <- 1..3, do: elem(:timer.tc(fn -> run.(bytes) end), 0))
  mb = byte_size(bytes) / 1_048_576

  IO.puts(
    "  #{String.pad_trailing(name, 12)} #{:erlang.float_to_binary(mb, decimals: 1)} MB " <>
      "in #{div(us, 1000)} ms = #{:erlang.float_to_binary(mb / (us / 1_000_000), decimals: 1)} MB/s"
  )
end

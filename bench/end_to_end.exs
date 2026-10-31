# The whole pipeline: a real shell `cat`s a file in a real window, through
# the PTY, the parser, the screen, the Window and the renderer (the release
# OpenGL build, on SDL's offscreen driver, drawing every frame). The clock
# stops when the screen has taken in the last byte: the shell then sets the
# title, and the window's Tabs hears of it. Book chapter 22.
#
#   mix run --no-start bench/end_to_end.exs        (or: make bench)
alias Guiltty.{Desk, Lifeline, Tabs}

Application.put_env(:guiltty, :autostart, false)
# The release renderer: the debug ones run under the sanitizers.
Application.put_env(:guiltty, :renderer, "guiltty_gl")
{:ok, _} = Application.ensure_all_started(:guiltty)

{:ok, _} =
  Supervisor.start_link(
    [
      {DynamicSupervisor, name: Guiltty.Sessions, strategy: :one_for_one},
      {DynamicSupervisor, name: Guiltty.Desks, strategy: :one_for_one},
      Lifeline
    ],
    strategy: :one_for_one
  )

dir = Path.join(System.tmp_dir!(), "guiltty-bench-#{System.unique_integer([:positive])}")
File.mkdir_p!(dir)

files = [
  {"scrolling", for(n <- 1..600_000, into: "", do: "#{n}\n")},
  {"colors",
   for n <- 1..40_000, into: "" do
     words = for w <- 1..12, do: "\e[#{31 + rem(n + w, 7)}mword#{w}\e[0m"
     Enum.join(words, " ") <> "\n"
   end}
]

env = [{~c"SDL_VIDEO_DRIVER", ~c"offscreen"}]

# Each window closes only once the next is open: closing the last one
# would stop guiltty (Guiltty.Lifeline), as it should.
Enum.reduce(files, nil, fn {name, text}, previous ->
  path = Path.join(dir, name)
  File.write!(path, text)

  # The shell waits for Enter, so the clock starts with the window ready.
  script = "stty -echo; read go; cat '#{path}'; printf '\\033]2;bench-done\\007'; sleep 600"
  session_opts = [shell: "/bin/sh", args: ["-c", script]]
  {:ok, desk} = Lifeline.open(window: [env: env], session_opts: session_opts)
  tabs = Desk.tabs(desk)

  wait = fn wait, test ->
    if test.(), do: :ok, else: Process.sleep(2) && wait.(wait, test)
  end

  # The window has shaken hands with its renderer and shows the tab.
  wait.(wait, fn ->
    Supervisor.which_children(Desk.name(desk))
    |> Enum.any?(fn
      {Guiltty.Window, pid, _, _} when is_pid(pid) -> :sys.get_state(pid).ready
      _ -> false
    end)
  end)

  id = Tabs.active(tabs)
  start = System.monotonic_time(:microsecond)
  Guiltty.Session.write(id, "\r")
  wait.(wait, fn -> match?({[{_, "bench-done"}], _}, Tabs.list(tabs)) end)
  us = System.monotonic_time(:microsecond) - start

  mb = byte_size(text) / 1_048_576

  IO.puts(
    "  #{String.pad_trailing(name, 12)} #{:erlang.float_to_binary(mb, decimals: 1)} MB " <>
      "in #{div(us, 1000)} ms = #{:erlang.float_to_binary(mb / (us / 1_000_000), decimals: 1)} MB/s"
  )

  if previous, do: Tabs.close_unlocked(previous)
  tabs
end)

File.rm_rf!(dir)

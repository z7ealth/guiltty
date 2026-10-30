defmodule Guiltty.Session.Parser do
  @moduledoc """
  Turns the shell's bytes into commands for the screen.

  On start it attaches to the session's `Pty`, which only then begins
  reading. Emits `[:guiltty, :parser, :parse]` with `%{duration, bytes}` for
  every chunk. If this process crashes, the `rest_for_one` supervisor restarts
  only the parser, and the new one attaches again.
  """

  use GenServer

  alias Guiltty.Parser
  alias Guiltty.Session
  alias Guiltty.Session.{Pty, Screen}

  def start_link(opts) do
    Session.start_named(opts[:id], :parser, &GenServer.start_link(__MODULE__, opts, name: &1))
  end

  @impl true
  def init(opts) do
    id = opts[:id]
    :ok = Pty.attach_parser(id, self())
    {:ok, %{id: id, parser: Parser.new()}}
  end

  # Parse, wait until the screen has applied it (Screen.apply is a call),
  # then tell the Pty it may read more. That's what chains the kernel's
  # buffer to the screen's speed.
  @impl true
  def handle_info({:pty_data, bytes}, state) do
    start = System.monotonic_time()
    {parser, commands} = Parser.feed(state.parser, bytes)

    :telemetry.execute(
      [:guiltty, :parser, :parse],
      %{duration: System.monotonic_time() - start, bytes: byte_size(bytes)},
      %{session: state.id}
    )

    if commands != [], do: Screen.apply(state.id, commands)
    Pty.ack(state.id)
    {:noreply, %{state | parser: parser}}
  end
end

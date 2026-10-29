defmodule Guiltty.Session.Parser do
  @moduledoc """
  Turns the shell's bytes into commands for the screen.

  On start it attaches to the session's `Pty`, which only then begins
  reading. If this process crashes, the `rest_for_one` supervisor restarts
  only the parser, and the new one attaches again.
  """

  use GenServer

  alias Guiltty.Parser
  alias Guiltty.Session
  alias Guiltty.Session.{Pty, Screen}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Session.via(opts[:id], :parser))
  end

  @impl true
  def init(opts) do
    id = opts[:id]
    :ok = Pty.attach_parser(id, self())
    {:ok, %{id: id, parser: Parser.new()}}
  end

  @impl true
  def handle_info({:pty_data, bytes}, state) do
    {parser, commands} = Parser.feed(state.parser, bytes)
    if commands != [], do: Screen.apply(state.id, commands)
    {:noreply, %{state | parser: parser}}
  end
end

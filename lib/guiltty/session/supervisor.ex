defmodule Guiltty.Session.Supervisor do
  @moduledoc """
  One terminal session: `Pty`, `Screen` and `Parser`, in that order.

  `rest_for_one` restarts a crashed child and everything started after it.
  A parser crash restarts only the parser and keeps the screen. A `Pty`
  crash restarts all three, because a new shell means a new screen.

  The `Pty` is significant: when the shell exits, the whole session shuts
  down instead of restarting.
  """

  use Supervisor, restart: :transient

  alias Guiltty.Session
  alias Guiltty.Session.{Parser, Pty, Screen}

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Session.via(opts[:id], :supervisor))
  end

  @impl true
  def init(opts) do
    children = [
      Supervisor.child_spec({Pty, opts}, significant: true),
      {Screen, opts},
      {Parser, opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one, auto_shutdown: :any_significant)
  end
end

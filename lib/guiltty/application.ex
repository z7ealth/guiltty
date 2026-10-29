defmodule Guiltty.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [{Registry, keys: :unique, name: Guiltty.Registry}] ++
        if Application.get_env(:guiltty, :autostart, true) do
          # Both are significant: when the shell exits or the window closes,
          # the application stops, and stopping takes the other one down.
          [
            Supervisor.child_spec({Guiltty.Session.Supervisor, id: :main}, significant: true),
            Supervisor.child_spec({Guiltty.Window, session: :main}, significant: true)
          ]
        else
          []
        end

    opts = [strategy: :one_for_one, name: Guiltty.Supervisor, auto_shutdown: :any_significant]
    Supervisor.start_link(children, opts)
  end
end

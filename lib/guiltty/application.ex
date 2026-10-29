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
          # The session is significant: when its shell exits, the app stops.
          [Supervisor.child_spec({Guiltty.Session.Supervisor, id: :main}, significant: true)]
        else
          []
        end

    opts = [strategy: :one_for_one, name: Guiltty.Supervisor, auto_shutdown: :any_significant]
    Supervisor.start_link(children, opts)
  end
end

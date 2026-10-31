defmodule Guiltty.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  #   Guiltty.Supervisor (rest_for_one)
  #   |-- Guiltty.Registry      names of every session's and desk's processes
  #   |-- Guiltty.Config        ~/.config/guiltty/config.exs, reloaded on save
  #   |-- Guiltty.Sessions      DynamicSupervisor: one Session.Supervisor per tab
  #   |-- Guiltty.Desks         DynamicSupervisor: one Desk per window (its
  #   |                         Tabs and its Window)
  #   |-- Guiltty.Lifeline      watches the desks (significant)
  #   `-- (a Task)              opens the first window at boot
  #
  # rest_for_one: each child depends on the ones before it. Lifeline is
  # significant: when the last desk ends, guiltty stops.
  @impl true
  def start(_type, _args) do
    children =
      [{Registry, keys: :unique, name: Guiltty.Registry}] ++
        if Application.get_env(:guiltty, :autostart, true) do
          [
            Guiltty.Config,
            {DynamicSupervisor, name: Guiltty.Sessions, strategy: :one_for_one},
            {DynamicSupervisor, name: Guiltty.Desks, strategy: :one_for_one},
            Supervisor.child_spec(Guiltty.Lifeline, significant: true),
            {Task, fn -> Guiltty.open_window() end}
          ]
        else
          []
        end

    opts = [strategy: :rest_for_one, name: Guiltty.Supervisor, auto_shutdown: :any_significant]
    Supervisor.start_link(children, opts)
  end

  # In a release nothing else runs in the VM, so once guiltty has stopped
  # there's no reason to keep it alive. Under iex or mix, leave it running.
  @impl true
  def stop(_state) do
    if System.get_env("RELEASE_NAME"), do: System.stop(0)
    :ok
  end
end

defmodule Guiltty.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  #   Guiltty.Supervisor (rest_for_one)
  #   |-- Guiltty.Registry      names of every session's processes
  #   |-- Guiltty.Config        ~/.config/guiltty/config.exs, reloaded on save
  #   |-- Guiltty.Sessions      DynamicSupervisor: one Session.Supervisor per tab
  #   |-- Guiltty.Tabs          tab order, active tab, titles (significant)
  #   |-- Guiltty.Windows       DynamicSupervisor: the Window, when one is open
  #   `-- (a Task)              opens the first window at boot
  #
  # rest_for_one: each child depends on the ones before it. Tabs is
  # significant: when the last tab closes, guiltty stops. Windows are not:
  # closing the window leaves the tabs running.
  @impl true
  def start(_type, _args) do
    children =
      [{Registry, keys: :unique, name: Guiltty.Registry}] ++
        if Application.get_env(:guiltty, :autostart, true) do
          [
            Guiltty.Config,
            {DynamicSupervisor, name: Guiltty.Sessions, strategy: :one_for_one},
            Supervisor.child_spec(Guiltty.Tabs, significant: true),
            {DynamicSupervisor, name: Guiltty.Windows, strategy: :one_for_one},
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

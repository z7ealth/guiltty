defmodule Guiltty.Tabs.Keeper do
  @moduledoc """
  Keeps a desk's tab layout safe while its `Guiltty.Tabs` restarts.

  The layout (which tabs, in which order, how each is split, names, locks)
  lives in an ETS table that `Tabs` owns and writes on every change. This
  process is the table's *heir*: when the owner dies, the BEAM hands the
  table to the heir instead of deleting it (`ets:new/2`, the `heir`
  option). The next `Tabs` calls `take/1` and gets it back, with what the
  old one last wrote.

      Desk (rest_for_one)
      ├── Keeper   holds the table only while no Tabs does
      ├── Tabs     owns it, writes it; dies → the table goes to Keeper
      └── Window

  Why a table and not this process's state: writing is a local
  `:ets.insert/2` in `Tabs`, with no message and no waiting, and the
  table is `:protected`, so only its owner can write it.
  """

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, nil, Keyword.take(opts, [:name]))

  @doc """
  Makes the calling process the table's owner, with this keeper as its
  heir, and returns the table. It's empty on a desk's first start, and
  holds what the last owner wrote after a restart.
  """
  def take(keeper), do: GenServer.call(keeper, :take)

  @impl true
  def init(nil) do
    table = :ets.new(:guiltty_tabs, [:set, :protected, heir: self()])
    {:ok, table}
  end

  @impl true
  def handle_call(:take, {pid, _}, table) do
    case await_owner(table) do
      :ok ->
        # The heir option stays as it was set: this process.
        :ets.give_away(table, pid, :taken)
        {:reply, table, table}

      :error ->
        {:reply, {:error, :busy}, table}
    end
  end

  @impl true
  def handle_info({:"ETS-TRANSFER", _table, _from, _data}, table), do: {:noreply, table}

  # A Tabs that just died may still hold the table for a moment: its exit
  # reached the supervisor, which started the new one, before the table's
  # transfer reached here. Wait a little for it.
  defp await_owner(table) do
    if :ets.info(table, :owner) == self() do
      :ok
    else
      receive do
        {:"ETS-TRANSFER", ^table, _from, _data} -> :ok
      after
        1_000 -> :error
      end
    end
  end
end

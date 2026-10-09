defmodule AlexClaw.Connections.Supervisor do
  @moduledoc """
  The database connections' pools: a registry by connection name and a
  dynamic supervisor holding one `AlexClaw.Connections.Pool` per defined
  connection (`AlexClaw.Connections.Pools`). A pool that cannot connect is
  down, never a crash, so nothing here takes the application with it.
  """
  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: AlexClaw.Connections.Registry},
      {DynamicSupervisor, name: AlexClaw.Connections.PoolSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end

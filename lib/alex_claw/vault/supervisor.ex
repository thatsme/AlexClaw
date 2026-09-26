defmodule AlexClaw.Vault.Supervisor do
  @moduledoc """
  The OpenBao client's own branch of the supervision tree: a client that keeps
  failing uses up this supervisor's restarts, and the root restarts the branch
  without touching any other child.
  """
  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(config), do: Supervisor.start_link(__MODULE__, config, name: __MODULE__)

  @impl true
  def init(config), do: Supervisor.init([{AlexClaw.Vault, config}], strategy: :one_for_one)
end

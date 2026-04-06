defmodule AlexClaw.Reasoning.Supervisor do
  @moduledoc "DynamicSupervisor for reasoning loop processes."

  use DynamicSupervisor
  require Logger

  def start_link(_arg) do
    result = DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
    cleanup_orphaned_sessions()
    result
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  defp cleanup_orphaned_sessions do
    case AlexClaw.Reasoning.cleanup_orphaned_sessions() do
      {0, _} -> :ok
      {count, _} -> Logger.info("[ReasoningSupervisor] Cleaned up #{count} orphaned session(s)")
    end
  rescue
    e -> Logger.warning("[ReasoningSupervisor] Cleanup failed: #{Exception.message(e)}")
  end
end

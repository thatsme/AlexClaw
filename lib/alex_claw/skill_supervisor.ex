defmodule AlexClaw.SkillSupervisor do
  @moduledoc """
  Dynamic supervisor for skill worker processes.
  Each skill run is an isolated, supervised process.
  """
  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end

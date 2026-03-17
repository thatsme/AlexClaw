defmodule AlexClaw.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AlexClaw.Repo,
      {Phoenix.PubSub, name: AlexClaw.PubSub},
      {Task.Supervisor, name: AlexClaw.TaskSupervisor},
      AlexClaw.LLM.UsageTracker,
      AlexClaw.Config.Loader,
      AlexClaw.LogBuffer,
      AlexClaw.Google.TokenManager,
      AlexClaw.RateLimiter.Server,
      AlexClaw.SkillSupervisor,
      AlexClaw.Scheduler,
      AlexClaw.Workflows.SchedulerSync,
      AlexClaw.Gateway,
      AlexClawWeb.Endpoint,
      AlexClaw.UpdateChecker
    ]

    opts = [strategy: :one_for_one, name: AlexClaw.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

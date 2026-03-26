defmodule AlexClaw.Application do
  @moduledoc "OTP application supervisor for AlexClaw."
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AlexClaw.Repo,
      {Phoenix.PubSub, name: AlexClaw.PubSub},
      {Task.Supervisor, name: AlexClaw.TaskSupervisor},
      AlexClaw.LLM.UsageTracker,
      AlexClaw.Config.Loader,
      AlexClaw.Workflows.SkillRegistry,
      AlexClaw.LogBuffer,
      AlexClaw.Google.TokenManager,
      AlexClaw.RateLimiter.Server,
      AlexClaw.Auth.SkillRateLimiter,
      {Registry, keys: :unique, name: AlexClaw.CircuitBreakerRegistry},
      AlexClaw.Skills.CircuitBreakerSupervisor,
      AlexClaw.SkillSupervisor,
      AlexClaw.Cluster.Manager,
      AlexClaw.Scheduler,
      AlexClaw.Workflows.SchedulerSync,
      AlexClaw.Gateway.Telegram,
      AlexClawWeb.Endpoint,
      AlexClaw.UpdateChecker,
      AlexClaw.Gateway.DiscordStarter
    ]

    opts = [strategy: :one_for_one, name: AlexClaw.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

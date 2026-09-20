defmodule AlexClaw.Application do
  @moduledoc "OTP application supervisor for AlexClaw."
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AlexClaw.Repo,
      {Phoenix.PubSub, name: AlexClaw.PubSub},
      {Task.Supervisor, name: AlexClaw.TaskSupervisor},
      AlexClaw.Knowledge.EmbedThrottle,
      AlexClaw.LLM.UsageTracker,
      AlexClaw.Config.Loader,
      AlexClaw.Workflows.SkillRegistry,
      AlexClaw.Workflows.Registry,
      AlexClaw.LogBuffer,
      AlexClaw.Google.TokenManager,
      AlexClaw.RateLimiter.Server,
      AlexClaw.Auth.SkillRateLimiter,
      # Owns the pending-2FA table, so a challenge outlives the LiveView or
      # gateway process that raised it. Must start before anything that can
      # raise one: the endpoint and the gateways.
      AlexClaw.Auth.ChallengeStore,
      {Registry, keys: :unique, name: AlexClaw.CircuitBreakerRegistry},
      AlexClaw.Skills.CircuitBreakerSupervisor,
      AlexClaw.SkillSupervisor,
      AlexClaw.Reasoning.Supervisor,
      {AlexClaw.MCP.Server, transport: {:streamable_http, start: true}},
      AlexClaw.Cluster.Manager,
      AlexClaw.Scheduler,
      AlexClaw.Gateway.Telegram,
      AlexClawWeb.Endpoint,
      AlexClaw.UpdateChecker
    ]

    opts = [strategy: :one_for_one, name: AlexClaw.Supervisor]
    Supervisor.start_link(children ++ background_children(), opts)
  end

  # Workers that query the database from a boot timer. Under the test sandbox
  # they own no connection, so each tick crashes them; three restarts inside
  # the supervisor's five-second window take the whole application down,
  # including the Repo.
  defp background_children do
    :alex_claw
    |> Application.get_env(:start_background_workers, true)
    |> background_children()
  end

  defp background_children(true) do
    [AlexClaw.Workflows.SchedulerSync, AlexClaw.Gateway.DiscordStarter]
  end

  defp background_children(false), do: []
end

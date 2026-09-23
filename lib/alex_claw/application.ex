defmodule AlexClaw.Application do
  @moduledoc "OTP application supervisor for AlexClaw."
  use Application

  alias AlexClaw.Database.PrivilegeCheck

  @impl true
  def start(_type, _args) do
    # Before anything starts: an instance connected as the database owner would
    # run with every power the role separation takes away. In production it
    # does not start at all.
    PrivilegeCheck.run!()

    # The content sanitizer's injection patterns, read once. Unreadable, the
    # start stops here rather than running with fewer defences than shipped.
    AlexClaw.ContentSanitizer.load_patterns!()

    children = [
      AlexClaw.Repo,
      {Phoenix.PubSub, name: AlexClaw.PubSub},
      {Task.Supervisor, name: AlexClaw.TaskSupervisor},
      # Before anything that audits: a row lost at boot is announced too.
      AlexClaw.Auth.AuditLoss,
      AlexClaw.Knowledge.EmbedThrottle,
      AlexClaw.LLM.UsageTracker,
      AlexClaw.Config.Loader,
      AlexClaw.Workflows.SkillRegistry,
      # Encrypts credentials still stored in plain text and checks the rest
      # decrypt, before anything reads them; the boot stops if one fails.
      AlexClaw.Database.EncryptCredentials,
      AlexClaw.Workflows.Registry,
      AlexClaw.LogBuffer,
      AlexClaw.Google.TokenManager,
      AlexClaw.RateLimiter.Server,
      AlexClaw.Auth.SkillRateLimiter,
      # Owns the pending-2FA table, so a challenge outlives the LiveView or
      # gateway process that raised it. Must start before anything that can
      # raise one: the endpoint and the gateways.
      AlexClaw.Auth.ChallengeStore,
      # Owns the admin elevation table. Before the endpoint for the same reason
      # as ChallengeStore: a page must never be served that cannot ask it.
      AlexClaw.Auth.Elevation,
      AlexClaw.Auth.CodeAttempts,
      # Owns the live-login table. Before the endpoint: no request or mount may
      # be judged before there is something to judge it against.
      AlexClaw.Auth.Sessions,
      {Registry, keys: :unique, name: AlexClaw.CircuitBreakerRegistry},
      AlexClaw.Skills.CircuitBreakerSupervisor,
      AlexClaw.SkillSupervisor,
      AlexClaw.Skills.ForgeGuard,
      AlexClaw.LLM.LocalLock,
      AlexClaw.WebAutomation.PlayLock,
      AlexClaw.Reasoning.Supervisor,
      {AlexClaw.MCP.Server, transport: {:streamable_http, start: true}},
      AlexClaw.Cluster.Manager,
      AlexClaw.Scheduler,
      # The gateways restart under their own supervisor, never against the root.
      AlexClaw.Gateway.Supervisor,
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
    [AlexClaw.Workflows.SchedulerSync]
  end

  defp background_children(false), do: []
end

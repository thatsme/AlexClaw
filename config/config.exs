import Config

config :alex_claw, ecto_repos: [AlexClaw.Repo]

config :alex_claw, AlexClaw.Repo,
  database: "alex_claw_#{config_env()}",
  hostname: "localhost",
  types: AlexClaw.PostgrexTypes,
  show_sensitive_data_on_connection_error: true

config :alex_claw, AlexClawWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: AlexClawWeb.ErrorHTML], layout: false],
  pubsub_server: AlexClaw.PubSub,
  live_view: [signing_salt: "alexclaw_lv"]

config :alex_claw, AlexClaw.Scheduler, jobs: []

config :alex_claw, AlexClaw.LLM,
  ollama_enabled: false,
  ollama_host: "http://localhost:11434",
  ollama_model: "llama3.2"

config :nostrum, :ffmpeg, false

config :elixir, :time_zone_database, Tz.TimeZoneDatabase

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :skill,
    :provider,
    :request_id,
    # Emitted by Workflows.Executor, Auth.AuditLog and Resources.ApiDiscovery.
    # A key the code passes but this list omits is silently dropped from output,
    # which is why authorization denials could not be filtered by caller or
    # permission even though the message text mentioned them.
    :workflow,
    :workflow_run_id,
    :auth,
    :caller,
    :caller_type,
    :permission,
    :chain_depth,
    :resource_id,
    :elevation,
    :code_attempt,
    :recovery_codes
  ]

# Timezone data ships with the release and is refreshed by rebuilding it. The
# updater polls for a newer copy and records the result inside its own priv/
# directory, which the container's read-only root filesystem refuses — thirteen
# crashes of :tzdata_release_updater in the first twenty seconds of a boot. It
# also means the app no longer calls out to iana.org at runtime.
config :tzdata, :autoupdate, :disabled

import_config "#{config_env()}.exs"

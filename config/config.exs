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

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:skill, :provider, :request_id]

import_config "#{config_env()}.exs"

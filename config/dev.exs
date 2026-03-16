import Config

config :alex_claw, AlexClaw.Repo,
  username: "postgres",
  password: "postgres",
  stacktrace: true,
  pool_size: 10

config :alex_claw, AlexClawWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 5001],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "dev_only_secret_key_base_that_is_at_least_64_bytes_long_for_alexclaw_dev_only!!",
  live_reload: [
    patterns: [
      ~r"lib/alex_claw_web/(live|components)/.*(ex|heex)$"
    ]
  ]

config :alex_claw, AlexClaw.Gateway,
  telegram_token: System.get_env("TELEGRAM_BOT_TOKEN"),
  chat_id: System.get_env("TELEGRAM_CHAT_ID"),
  poll_interval: 1_000

config :phoenix, :plug_init_mode, :runtime

import Config

config :alex_claw, AlexClaw.Repo,
  username: System.get_env("DATABASE_USERNAME", "alexclaw"),
  password: System.get_env("DATABASE_PASSWORD", "alexclaw_dev_2026"),
  hostname: System.get_env("DATABASE_HOSTNAME", "localhost"),
  database: "alex_claw_test#{System.get_env("MIX_TEST_PARTITION")}",
  port: String.to_integer(System.get_env("DATABASE_PORT", "5432")),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :alex_claw, AlexClaw.Gateway,
  telegram_token: "test-token",
  chat_id: "test-chat-id",
  poll_interval: :infinity

config :logger, level: :warning

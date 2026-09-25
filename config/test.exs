import Config

config :alex_claw, AlexClaw.Repo,
  username: System.get_env("DATABASE_USERNAME", "alexclaw"),
  password: System.get_env("DATABASE_PASSWORD", "alexclaw_dev_2026"),
  hostname: System.get_env("DATABASE_HOSTNAME", "localhost"),
  database: "alex_claw_test#{System.get_env("MIX_TEST_PARTITION")}",
  port: String.to_integer(System.get_env("DATABASE_PORT", "5432")),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# The test stack's OpenBao, initialised for each run by openbao-test-init,
# which leaves AlexClaw's AppRole credentials and the CA in the bootstrap mount.
config :alex_claw, AlexClaw.Vault,
  address: "https://openbao-test:8200",
  ca_file: "/run/alexclaw/openbao/ca.pem",
  role_id_file: "/run/alexclaw/openbao/role_id",
  secret_id_file: "/run/alexclaw/openbao/secret_id"

config :alex_claw, AlexClaw.Gateway,
  telegram_token: "test-token",
  chat_id: "test-chat-id",
  poll_interval: :infinity

config :alex_claw, AlexClawWeb.Endpoint,
  secret_key_base:
    "test_only_secret_key_base_that_is_at_least_64_bytes_long_for_alexclaw_test_only!!"

config :alex_claw, skip_provider_seed: true
config :alex_claw, start_background_workers: false
config :alex_claw, :skills_dir, Path.expand("../tmp/test_skills", __DIR__)

config :nostrum, token: ""

config :logger, level: :warning

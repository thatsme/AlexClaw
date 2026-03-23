import Config

config :alex_claw, :skills_dir, System.get_env("SKILLS_DIR", "/app/skills")

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE not set. Generate with: mix phx.gen.secret"

  config :alex_claw, AlexClawWeb.Endpoint,
    secret_key_base: secret_key_base

  config :alex_claw, AlexClaw.Repo,
    username: System.fetch_env!("DATABASE_USERNAME"),
    password: System.fetch_env!("DATABASE_PASSWORD"),
    hostname: System.fetch_env!("DATABASE_HOSTNAME"),
    pool_size: (case Integer.parse(System.get_env("POOL_SIZE") || "10") do
      {n, _} -> n
      :error -> 10
    end)

  config :alex_claw, admin_password: System.get_env("ADMIN_PASSWORD")

  config :alex_claw, AlexClaw.Gateway,
    telegram_token: System.get_env("TELEGRAM_BOT_TOKEN"),
    chat_id: System.get_env("TELEGRAM_CHAT_ID"),
    poll_interval: 1_000

  config :alex_claw, AlexClaw.LLM,
    ollama_enabled: System.get_env("OLLAMA_ENABLED") == "true",
    ollama_host: System.get_env("OLLAMA_HOST", "http://localhost:11434"),
    ollama_model: System.get_env("OLLAMA_MODEL", "llama3.2")

  config :alex_claw, :node_name, System.get_env("NODE_NAME")
end

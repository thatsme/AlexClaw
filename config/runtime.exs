import Config

config :alex_claw, :skills_dir, System.get_env("SKILLS_DIR", "/app/skills")

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE not set. Generate with: mix phx.gen.secret"

  config :alex_claw, AlexClawWeb.Endpoint, secret_key_base: secret_key_base

  config :alex_claw, AlexClaw.Repo,
    username: System.fetch_env!("DATABASE_USERNAME"),
    password: System.fetch_env!("DATABASE_PASSWORD"),
    hostname: System.fetch_env!("DATABASE_HOSTNAME"),
    pool_size:
      (case Integer.parse(System.get_env("POOL_SIZE") || "10") do
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

  # The Erlang cookie is a remote shell. A node running with a value that ships
  # in this repository will accept a connection from anyone who can reach its
  # distribution port, and run whatever they send as the application. The
  # default compose file supplied exactly such a value.
  #
  # Treated like SECRET_KEY_BASE rather than like ADMIN_PASSWORD, which is read
  # with a bare get_env and boots without it, so that its absence surfaces as a
  # message on the login page. An absent cookie is not a message, it is a stop.
  #
  # entrypoint.sh is what hands this to the release, as RELEASE_COOKIE.
  cluster_cookie =
    System.get_env("CLUSTER_COOKIE") ||
      raise """
      CLUSTER_COOKIE not set.

      Any process that can reach this node's distribution port and knows the
      cookie can run code as the application. Generate one with:

          openssl rand -base64 32
      """

  if cluster_cookie in ~w(alexclaw_default alexclaw_swarm) do
    raise """
    CLUSTER_COOKIE is #{cluster_cookie}, a value that ships in this
    repository and is therefore public. Generate a real one with:

        openssl rand -base64 32
    """
  end

  config :alex_claw, :node_name, System.get_env("NODE_NAME")
end

import Config

config :alex_claw, :skills_dir, System.get_env("SKILLS_DIR", "/app/skills")

# The shared token the web-automator sidecar requires on every route but
# /health. Unset or empty, AlexClaw sends nothing to the sidecar.
config :alex_claw, :web_automator_token, System.get_env("WEB_AUTOMATOR_TOKEN")

if config_env() == :prod do
  # The migrate service runs an eval with the database owner's credentials and,
  # by design, without SECRET_KEY_BASE: the two never share a container. An
  # eval serves nothing to sign, and anything there that tries to encrypt or
  # decrypt raises (AlexClaw.Config.Crypto). Every other command needs the key.
  secret_key_base =
    case {System.get_env("SECRET_KEY_BASE"), System.get_env("RELEASE_COMMAND")} do
      {key, "eval"} when key in [nil, ""] ->
        nil

      {key, _} when key in [nil, ""] ->
        raise "SECRET_KEY_BASE not set. Generate one with: openssl rand -base64 48"

      # Phoenix's cookie store needs 64 bytes; shorter, the login page itself
      # fails. It is also the key the stored secrets are encrypted with.
      {key, _} when byte_size(key) < 64 ->
        raise "SECRET_KEY_BASE is #{byte_size(key)} bytes; it must be at least 64. " <>
                "Generate one with: openssl rand -base64 48"

      {key, _} ->
        key
    end

  # Explicit, rather than inherited from url: [host: ...]. Phoenix falls back to
  # that host when check_origin is unset, which made the endpoint accept
  # "localhost" and refuse "127.0.0.1" — and 0.3.28 bound the published port to
  # 127.0.0.1. The page rendered, the LiveView socket was rejected, and every
  # button on every page did nothing. The only trace was one line in the log:
  # "Could not check origin for Phoenix.Socket transport."
  #
  # Both loopback spellings by default, because both are things an operator
  # types, on the port the host publishes (ADMIN_PORT; the endpoint itself
  # always listens on 5001 inside the container). PHX_HOST adds the public
  # origin behind a proxy; CHECK_ORIGIN replaces the list outright when
  # neither fits.
  admin_port =
    case Integer.parse(System.get_env("ADMIN_PORT") || "5001") do
      {port, ""} when port in 1..65_535 -> port
      _ -> raise "ADMIN_PORT must be a port number (1-65535)"
    end

  check_origin =
    case System.get_env("CHECK_ORIGIN") do
      value when value in [nil, ""] ->
        ["http://localhost:#{admin_port}", "http://127.0.0.1:#{admin_port}"] ++
          case System.get_env("PHX_HOST") do
            host when host in [nil, ""] -> []
            host -> ["https://#{host}"]
          end

      list ->
        list |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    end

  config :alex_claw, AlexClawWeb.Endpoint,
    secret_key_base: secret_key_base,
    check_origin: check_origin

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

  # The running application must connect as its own restricted role, never as
  # the database owner: the boot stops otherwise. Unconditional, by design —
  # see AlexClaw.Database.PrivilegeCheck.
  config :alex_claw, enforce_db_privileges: true

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

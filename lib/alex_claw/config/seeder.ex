defmodule AlexClaw.Config.Seeder do
  @moduledoc """
  Seeds default runtime config values on first boot.
  Only creates settings that don't already exist.
  """
  alias AlexClaw.Config

  # {key, value_or_fn, type, category, description, sensitive}
  @defaults [
    # Telegram
    {"telegram.enabled", "true", "boolean", "telegram",
     "Enable Telegram gateway polling", false},
    {"telegram.bot_token", &__MODULE__.env/1, "string", "telegram", "Telegram Bot API token",
     true},
    {"telegram.chat_id", &__MODULE__.env/1, "string", "telegram",
     "Telegram chat ID for notifications", false},
    {"telegram.poll_interval", "1000", "integer", "telegram", "Telegram polling interval in ms",
     false},
    {"telegram.node", "", "string", "telegram",
     "Cluster: only this node runs the Telegram bot. Empty = any node", false},

    # Discord — static defaults only, no env override (configured from Admin UI)
    {"discord.enabled", "false", "boolean", "discord",
     "Enable Discord gateway (requires bot token and container restart)", false},
    {"discord.bot_token", "", "string", "discord",
     "Discord Bot token from Developer Portal", true},
    {"discord.channel_id", "", "string", "discord",
     "Discord channel ID for commands (auto-detected on first message)", false},
    {"discord.guild_id", "", "string", "discord",
     "Discord server (guild) ID", false},
    {"discord.node", "", "string", "discord",
     "Cluster: only this node runs the Discord bot. Empty = cluster-wide (any node)", false},

    # LLM - API Keys
    {"llm.gemini_api_key", &__MODULE__.env/1, "string", "llm", "Google Gemini API key", true},
    {"llm.anthropic_api_key", &__MODULE__.env/1, "string", "llm", "Anthropic API key", true},

    # LLM - Ollama
    {"llm.ollama_enabled", &__MODULE__.env/1, "boolean", "llm", "Enable local Ollama model",
     false},
    {"llm.ollama_host", &__MODULE__.env/1, "string", "llm", "Ollama API host URL", false},
    {"llm.ollama_model", &__MODULE__.env/1, "string", "llm", "Ollama model name", false},

    # LLM - LM Studio (OpenAI-compatible)
    {"llm.lmstudio_enabled", &__MODULE__.env/1, "boolean", "llm", "Enable LM Studio local model",
     false},
    {"llm.lmstudio_host", &__MODULE__.env/1, "string", "llm", "LM Studio API host URL", false},
    {"llm.lmstudio_model", &__MODULE__.env/1, "string", "llm", "LM Studio model name", false},

    # LLM - Tier limits (requests per day)
    {"llm.limit.gemini_flash", "250", "integer", "llm", "Gemini Flash daily request limit",
     false},
    {"llm.limit.gemini_pro", "50", "integer", "llm", "Gemini Pro daily request limit", false},
    {"llm.limit.haiku", "1000", "integer", "llm", "Claude Haiku daily request limit", false},
    {"llm.limit.sonnet", "5", "integer", "llm", "Claude Sonnet daily request limit", false},

    # Embeddings
    {"embedding.provider", "", "string", "embedding",
     "Provider name for embeddings (empty = auto-detect: Gemini > Ollama > OpenAI-compatible)",
     false},
    {"embedding.model", "gemini-embedding-001", "string", "embedding",
     "Embedding model name (Gemini: gemini-embedding-001, Ollama: nomic-embed-text)", false},

    # Skill defaults (per-skill LLM tier/provider for chat invocation)
    {"skill.research.tier", "medium", "string", "skill.research",
     "LLM tier for /research command (light, medium, heavy, local)", false},
    {"skill.research.provider", "auto", "string", "skill.research",
     "LLM provider for /research (auto = tier-based selection)", false},
    {"skill.conversational.tier", "light", "string", "skill.conversational",
     "LLM tier for free-text conversation", false},
    {"skill.conversational.provider", "auto", "string", "skill.conversational",
     "LLM provider for conversation", false},
    {"skill.web_search.tier", "medium", "string", "skill.web_search",
     "LLM tier for /search command", false},
    {"skill.web_search.provider", "auto", "string", "skill.web_search",
     "LLM provider for /search", false},
    {"skill.web_browse.tier", "light", "string", "skill.web_browse",
     "LLM tier for /web command", false},
    {"skill.web_browse.provider", "auto", "string", "skill.web_browse",
     "LLM provider for /web", false},
    {"skill.github_review.tier", "medium", "string", "skill.github_review",
     "LLM tier for GitHub security review", false},
    {"skill.github_review.provider", "auto", "string", "skill.github_review",
     "LLM provider for GitHub review", false},

    # Skills - RSS
    {"skills.rss.relevance_threshold", "0.7", "float", "skills",
     "Minimum relevance score for RSS items (0.0-1.0)", false},
    {"skills.rss.fetch_timeout", "15", "integer", "skills",
     "RSS feed fetch timeout in seconds (per feed)", false},

    # GitHub
    {"github.token", "", "string", "github",
     "GitHub personal access token (repo:read scope minimum)", true},
    {"github.webhook_secret", "", "string", "github", "GitHub webhook HMAC-SHA256 secret", true},
    {"github.default_repo", "", "string", "github",
     "Default repo for workflow steps (owner/repo format, e.g. myuser/myrepo)", false},
    {"github.watched_branches", "main,master", "string", "github",
     "Comma-separated branch names to review on push events", false},
    {"github.security_focus", "", "string", "github",
     "Custom security focus areas (leave blank to use built-in defaults)", false},

    # Google OAuth (Calendar, Keep, etc.)
    {"google.oauth.client_id", &__MODULE__.env/1, "string", "google", "Google OAuth client ID",
     false},
    {"google.oauth.client_secret", &__MODULE__.env/1, "string", "google",
     "Google OAuth client secret", true},
    {"google.oauth.refresh_token", &__MODULE__.env/1, "string", "google",
     "Google OAuth refresh token (obtained via one-time authorization flow)", true},
    {"google.oauth.redirect_uri", &__MODULE__.env/1, "string", "google",
     "Google OAuth redirect URI (default: http://localhost:5001/auth/google/callback)", false},

    # Web Automator (optional sidecar)
    {"web_automator.enabled", &__MODULE__.env/1, "boolean", "web_automator",
     "Enable web-automator browser automation sidecar", false},
    {"web_automator.host", &__MODULE__.env/1, "string", "web_automator",
     "Web-automator sidecar URL", false},

    # Shell (container introspection)
    {"shell.enabled", "false", "boolean", "shell",
     "Enable /shell command for container introspection", false},
    {"shell.whitelist",
     ~s(["df","free","ps","uptime","cat /proc","ping","nslookup","curl","bin/alex_claw","uname","whoami","hostname","date","ls","git"]),
     "string", "shell", "JSON array of allowed command prefixes", false},
    {"shell.blocklist",
     ~s(["&&","||","|",";","`","$(",">","<","\\n"]),
     "string", "shell", "JSON array of blocked metacharacters/sequences", false},
    {"shell.timeout_seconds", "30", "integer", "shell",
     "Max seconds before killing a shell command", false},
    {"shell.max_output_chars", "4000", "integer", "shell",
     "Max characters of command output before truncation", false},

    # Display
    {"display.timezone", "Europe/Rome", "string", "display",
     "Timezone for displaying dates/times in the UI (IANA format, e.g. Europe/Rome)", false},

    # Auth - 2FA
    {"auth.totp.enabled", "false", "boolean", "auth",
     "2FA enabled — required for skill management and sensitive operations", false},
    {"auth.totp.secret", "", "string", "auth",
     "TOTP secret (Base32). Generated by /setup 2fa", true},

    # Auth - Security
    {"auth.trust_proxy_headers", "false", "boolean", "auth",
     "Trust X-Forwarded-For header for client IP (enable only behind a reverse proxy)", false},

    # Auth - Rate limiting
    {"auth.rate_limit.max_attempts", "5", "integer", "auth",
     "Max failed login attempts before IP is blocked", false},
    {"auth.rate_limit.block_duration_seconds", "900", "integer", "auth",
     "How long (seconds) to block an IP after max failures (default: 15 minutes)", false},
    {"auth.rate_limit.window_seconds", "300", "integer", "auth",
     "Sliding window in seconds for attempt counting (default: 5 minutes)", false},

    # Prompts - Identity
    {"identity.name", "AlexClaw", "string", "identity", "Agent display name", false},
    {"identity.persona", "", "string", "identity",
     "Custom persona additions (appended to system prompt)", false},
    {"identity.base_prompt",
     "You are {name}, a personal AI agent running on Elixir/OTP.\nYou are direct, technically precise, and occasionally dry. You skip pleasantries.\nYou never pad responses with disclaimers.\nWhen in doubt, ask one focused question rather than making assumptions.",
     "string", "prompts", "Base identity system prompt. Use {name} as placeholder.", false},

    # Prompts - Skill context fragments
    {"prompts.context.rss", "You are currently processing news feeds.", "string", "prompts",
     "System prompt addition when running RSS skill", false},
    {"prompts.context.research", "You are conducting deep research.", "string", "prompts",
     "System prompt addition when running Research skill", false},
    {"prompts.context.conversational",
     "You are in direct conversation with the user via Telegram. Keep responses concise.",
     "string", "prompts", "System prompt addition for conversational mode", false},

    # Prompts - RSS scoring
    {"prompts.rss.scoring",
     "Score relevance 0.0-1.0 for the following interests:\nBEAM ecosystem, Elixir, Erlang, infrastructure, DevOps, cybersecurity, world news, geopolitics, international conflicts, technology policy.\n\nTitle: {title}\nDescription: {description}\n\nReply with ONLY a float number, nothing else.",
     "string", "prompts",
     "Prompt template for RSS relevance scoring. Use {title} and {description} placeholders.",
     false},

    # Prompts - Research
    {"prompts.research.system",
     "Provide a concise, technically precise summary. Include key facts and links if known.",
     "string", "prompts", "System instruction appended to research queries", false},

    # Cluster
    {"cluster.enabled", "false", "boolean", "cluster",
     "Enable BEAM clustering for multi-node workflow distribution", false},

    # Backup
    {"backup.enabled", "false", "boolean", "backup",
     "Enable scheduled database backups (requires bind mount in docker-compose.yml)", false},
    {"backup.max_files", "7", "integer", "backup",
     "Max backup files to keep (oldest are rotated out)", false},

    # Reasoning loop
    {"reasoning.enabled", "true", "boolean", "reasoning",
     "Enable reasoning loop feature (autonomous plan-execute-evaluate loop)", false},
    {"reasoning.max_iterations", "15", "integer", "reasoning",
     "Maximum loop iterations before forced stop", false},
    {"reasoning.max_llm_calls", "60", "integer", "reasoning",
     "Maximum total LLM calls per reasoning session", false},
    {"reasoning.time_budget_seconds", "900", "integer", "reasoning",
     "Maximum wall-clock time in seconds (default 15 minutes)", false},
    {"reasoning.skill_whitelist",
     ~s(["web_search","web_fetch","web_search_fetch","research","llm_transform","google_calendar","google_tasks","rss_fetch"]),
     "json", "reasoning",
     "Skills the reasoning loop may invoke (JSON array of skill names)", false},
    {"reasoning.stuck_threshold", "3", "integer", "reasoning",
     "Consecutive failures before declaring stuck", false},
    {"reasoning.step_timeout_seconds", "120", "integer", "reasoning",
     "Per-skill execution timeout in seconds", false},
    {"reasoning.max_plan_steps", "8", "integer", "reasoning",
     "Maximum steps the LLM can include in a plan", false},
    {"reasoning.done_confidence_threshold", "0.7", "string", "reasoning",
     "Minimum confidence (0.0-1.0) to accept a done declaration", false},
    {"reasoning.default_delivery",
     ~s(["memory"]),
     "json", "reasoning",
     "Delivery channels on completion: memory, telegram, discord (JSON array)", false},

    # Reasoning prompts (editable at runtime)
    {"prompts.reasoning.planning", "", "string", "prompts",
     "Planning prompt template for reasoning loop. Leave empty for default. Placeholders: {goal}, {skill_list}, {working_memory}, {prior_knowledge}, {max_steps}",
     false},
    {"prompts.reasoning.execution", "", "string", "prompts",
     "Execution prompt template. Placeholders: {skill_name}, {skill_description}, {step_description}, {previous_results}, {working_memory}, {user_guidance_section}",
     false},
    {"prompts.reasoning.evaluation", "", "string", "prompts",
     "Evaluation prompt template. Placeholders: {goal}, {step_description}, {skill_name}, {skill_output}, {working_memory}",
     false},
    {"prompts.reasoning.decision", "", "string", "prompts",
     "Decision prompt template. Placeholders: {goal}, {plan_summary}, {completed_steps}, {iteration}, {max_iterations}, {consecutive_failures}, {working_memory}, {user_guidance_section}",
     false}
  ]

  @env_mapping %{
    "telegram.bot_token" => {"TELEGRAM_BOT_TOKEN", ""},
    "telegram.chat_id" => {"TELEGRAM_CHAT_ID", ""},
    "llm.gemini_api_key" => {"GEMINI_API_KEY", ""},
    "llm.anthropic_api_key" => {"ANTHROPIC_API_KEY", ""},
    "llm.ollama_enabled" => {"OLLAMA_ENABLED", "false"},
    "llm.ollama_host" => {"OLLAMA_HOST", "http://localhost:11434"},
    "llm.ollama_model" => {"OLLAMA_MODEL", "llama3.2"},
    "llm.lmstudio_enabled" => {"LMSTUDIO_ENABLED", "false"},
    "llm.lmstudio_host" => {"LMSTUDIO_HOST", "http://host.docker.internal:1234"},
    "llm.lmstudio_model" => {"LMSTUDIO_MODEL", "qwen2.5-14b-instruct"},
    "google.oauth.client_id" => {"GOOGLE_OAUTH_CLIENT_ID", ""},
    "google.oauth.client_secret" => {"GOOGLE_OAUTH_CLIENT_SECRET", ""},
    "google.oauth.refresh_token" => {"GOOGLE_OAUTH_REFRESH_TOKEN", ""},
    "google.oauth.redirect_uri" => {"GOOGLE_OAUTH_REDIRECT_URI", ""},
    "web_automator.enabled" => {"WEB_AUTOMATOR_ENABLED", "false"},
    "web_automator.host" => {"WEB_AUTOMATOR_HOST", "http://web-automator:6900"},
  }

  @spec env(String.t()) :: String.t()
  def env(key) do
    case Map.get(@env_mapping, key) do
      {env_var, default} -> System.get_env(env_var) || default
      nil -> ""
    end
  end

  @spec seed() :: :ok
  def seed do
    for {key, value_or_fn, type, category, description, sensitive} <- @defaults do
      existing = Config.get(key)

      value =
        if is_function(value_or_fn, 1) do
          value_or_fn.(key)
        else
          value_or_fn
        end

      opts = [type: type, category: category, description: description, sensitive: sensitive]

      cond do
        is_nil(existing) ->
          Config.set(key, value, opts)

        true ->
          # Ensure sensitive flag is set even for existing settings
          if sensitive do
            case AlexClaw.Repo.get_by(AlexClaw.Config.Setting, key: key) do
              %{sensitive: false} = record ->
                record
                |> Ecto.Changeset.change(%{sensitive: true})
                |> AlexClaw.Repo.update()

              _ ->
                :ok
            end
          end

          :ok
      end
    end

    :ok
  end
end

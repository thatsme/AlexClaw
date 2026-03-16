defmodule AlexClaw.Config.Seeder do
  @moduledoc """
  Seeds default runtime config values on first boot.
  Only creates settings that don't already exist.
  """
  alias AlexClaw.Config

  @defaults [
    # Telegram
    {"telegram.bot_token", &__MODULE__.env/1, "string", "telegram",
     "Telegram Bot API token"},
    {"telegram.chat_id", &__MODULE__.env/1, "string", "telegram",
     "Telegram chat ID for notifications"},
    {"telegram.poll_interval", "1000", "integer", "telegram",
     "Telegram polling interval in ms"},

    # LLM - API Keys
    {"llm.gemini_api_key", &__MODULE__.env/1, "string", "llm",
     "Google Gemini API key"},
    {"llm.anthropic_api_key", &__MODULE__.env/1, "string", "llm",
     "Anthropic API key"},

    # LLM - Ollama
    {"llm.ollama_enabled", &__MODULE__.env/1, "boolean", "llm",
     "Enable local Ollama model"},
    {"llm.ollama_host", &__MODULE__.env/1, "string", "llm",
     "Ollama API host URL"},
    {"llm.ollama_model", &__MODULE__.env/1, "string", "llm",
     "Ollama model name"},

    # LLM - LM Studio (OpenAI-compatible)
    {"llm.lmstudio_enabled", &__MODULE__.env/1, "boolean", "llm",
     "Enable LM Studio local model"},
    {"llm.lmstudio_host", &__MODULE__.env/1, "string", "llm",
     "LM Studio API host URL"},
    {"llm.lmstudio_model", &__MODULE__.env/1, "string", "llm",
     "LM Studio model name"},

    # LLM - Tier limits (requests per day)
    {"llm.limit.gemini_flash", "250", "integer", "llm", "Gemini Flash daily request limit"},
    {"llm.limit.gemini_pro", "50", "integer", "llm", "Gemini Pro daily request limit"},
    {"llm.limit.haiku", "1000", "integer", "llm", "Claude Haiku daily request limit"},
    {"llm.limit.sonnet", "5", "integer", "llm", "Claude Sonnet daily request limit"},

    # Skills - RSS
    {"skills.rss.relevance_threshold", "0.7", "float", "skills",
     "Minimum relevance score for RSS items (0.0-1.0)"},

    # GitHub
    {"github.token", "", "string", "github",
     "GitHub personal access token (repo:read scope minimum)"},
    {"github.webhook_secret", "", "string", "github",
     "GitHub webhook HMAC-SHA256 secret"},
    {"github.default_repo", "", "string", "github",
     "Default repo for workflow steps (owner/repo format, e.g. myuser/myrepo)"},
    {"github.watched_branches", "main,master", "string", "github",
     "Comma-separated branch names to review on push events"},
    {"github.security_focus", "", "string", "github",
     "Custom security focus areas (leave blank to use built-in defaults)"},

    # Google OAuth (Calendar, Keep, etc.)
    {"google.oauth.client_id", &__MODULE__.env/1, "string", "google",
     "Google OAuth client ID"},
    {"google.oauth.client_secret", &__MODULE__.env/1, "string", "google",
     "Google OAuth client secret"},
    {"google.oauth.refresh_token", &__MODULE__.env/1, "string", "google",
     "Google OAuth refresh token (obtained via one-time authorization flow)"},
    {"google.oauth.redirect_uri", &__MODULE__.env/1, "string", "google",
     "Google OAuth redirect URI (default: http://localhost:5001/auth/google/callback)"},

    # Web Automator (optional sidecar)
    {"web_automator.enabled", &__MODULE__.env/1, "boolean", "web_automator",
     "Enable web-automator browser automation sidecar"},
    {"web_automator.host", &__MODULE__.env/1, "string", "web_automator",
     "Web-automator sidecar URL"},

    # Auth - Rate limiting
    {"auth.rate_limit.max_attempts", "5", "integer", "auth",
     "Max failed login attempts before IP is blocked"},
    {"auth.rate_limit.block_duration_seconds", "900", "integer", "auth",
     "How long (seconds) to block an IP after max failures (default: 15 minutes)"},
    {"auth.rate_limit.window_seconds", "300", "integer", "auth",
     "Sliding window in seconds for attempt counting (default: 5 minutes)"},

    # Prompts - Identity
    {"identity.name", "AlexClaw", "string", "identity", "Agent display name"},
    {"identity.persona", "", "string", "identity",
     "Custom persona additions (appended to system prompt)"},
    {"identity.base_prompt",
     "You are {name}, a personal AI agent running on Elixir/OTP.\nYou are direct, technically precise, and occasionally dry. You skip pleasantries.\nYou never pad responses with disclaimers.\nWhen in doubt, ask one focused question rather than making assumptions.",
     "string", "prompts", "Base identity system prompt. Use {name} as placeholder."},

    # Prompts - Skill context fragments
    {"prompts.context.rss", "You are currently processing news feeds.", "string", "prompts",
     "System prompt addition when running RSS skill"},
    {"prompts.context.research", "You are conducting deep research.", "string", "prompts",
     "System prompt addition when running Research skill"},
    {"prompts.context.conversational",
     "You are in direct conversation with the user via Telegram. Keep responses concise.",
     "string", "prompts", "System prompt addition for conversational mode"},

    # Prompts - RSS scoring
    {"prompts.rss.scoring",
     "Score relevance 0.0-1.0 for the following interests:\nBEAM ecosystem, Elixir, Erlang, infrastructure, DevOps, cybersecurity, world news, geopolitics, international conflicts, technology policy.\n\nTitle: {title}\nDescription: {description}\n\nReply with ONLY a float number, nothing else.",
     "string", "prompts", "Prompt template for RSS relevance scoring. Use {title} and {description} placeholders."},

    # Prompts - Research
    {"prompts.research.system",
     "Provide a concise, technically precise summary. Include key facts and links if known.",
     "string", "prompts", "System instruction appended to research queries"}
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
    for {key, value_or_fn, type, category, description} <- @defaults do
      existing = Config.get(key)

      value =
        if is_function(value_or_fn, 1) do
          value_or_fn.(key)
        else
          value_or_fn
        end

      cond do
        is_nil(existing) ->
          Config.set(key, value, type: type, category: category, description: description)

        is_function(value_or_fn, 1) and value != "" and to_string(existing) != value ->
          Config.set(key, value, type: type, category: category, description: description)

        true ->
          :ok
      end
    end

    :ok
  end
end

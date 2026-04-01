# Configuration

All configuration is managed at runtime through the Admin UI (`/config`). On first boot, values are seeded from environment variables. After that, changes are made in the UI — no restart needed.

## How It Works

```
Environment variables (.env) ──seed on first boot──> PostgreSQL (settings table)
                                                           │
                                                     ETS cache (fast reads)
                                                           │
                                                     Admin UI (edit at runtime)
                                                           │
                                                     PubSub broadcast (live updates)
```

- Settings are stored in the `settings` table with key, value, type, category, and sensitivity flag
- On startup, all settings are loaded into an ETS table for O(1) reads
- Changes via the Admin UI update both the database and ETS cache immediately
- PubSub broadcasts notify all subscribers of changes in real-time

## Required Environment Variables

These must be set in `.env` before first boot:

| Variable | Description |
|---|---|
| `DATABASE_PASSWORD` | PostgreSQL password |
| `SECRET_KEY_BASE` | Phoenix session secret (`openssl rand -base64 64`) |
| `ADMIN_PASSWORD` | Web interface login password |
| `TELEGRAM_BOT_TOKEN` | From @BotFather |
| `TELEGRAM_CHAT_ID` | Your Telegram chat ID |

## LLM Providers

At least one LLM provider is required:

| Variable | Description |
|---|---|
| `GEMINI_API_KEY` | Google Gemini (free tier available) |
| `ANTHROPIC_API_KEY` | Anthropic Claude |
| `OLLAMA_ENABLED=true` + `OLLAMA_HOST` | Local Ollama instance |
| `LMSTUDIO_ENABLED=true` + `LMSTUDIO_HOST` | Local LM Studio instance |

After first boot, providers are managed from **Admin > LLM Providers**. You can add, remove, reorder priorities, enable/disable providers, and configure per-provider inference options (e.g., `num_ctx`, `temperature`) — stored in an `options` JSON column on each provider. The LLM page shows a dynamic options form that adapts to the provider type. The `embedding.provider` setting is configured via a dropdown of enabled provider names on the Config page.

## Discord (Optional)

| Variable | Description |
|---|---|
| `DISCORD_ENABLED=true` | Enable the Discord gateway |
| `DISCORD_BOT_TOKEN` | Discord bot token |
| `DISCORD_CHANNEL_ID` | Command channel ID |
| `DISCORD_GUILD_ID` | Server (guild) ID |

## Config Categories

Settings are organized by category in the Admin UI:

| Category | Examples |
|---|---|
| `general` | Admin password, session settings |
| `skills` | RSS thresholds, fetch timeouts, shell whitelist |
| `prompts` | System prompts, context templates |
| `llm` | Provider-specific settings |
| `identity` | Agent name, base prompt |
| `mcp` | MCP API key, tool timeout |
| `github` | Webhook secret, review settings |

## Sensitive Values

Settings marked as `sensitive: true` are AES-256-GCM encrypted in the database. The Admin UI shows partial values (masked). Sensitive settings include API keys, OAuth tokens, and webhook secrets.

## Programmatic Access

From Elixir code:

```elixir
# Read (from ETS cache — fast)
AlexClaw.Config.get("skills.rss.relevance_threshold", 0.7)

# Write (updates DB + ETS + broadcasts)
AlexClaw.Config.set("skills.rss.relevance_threshold", 0.8,
  type: "float",
  category: "skills"
)
```

See the full list of bootstrap variables in [`.env.example`](https://github.com/thatsme/AlexClaw/blob/main/.env.example).

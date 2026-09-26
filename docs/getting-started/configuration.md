# Configuration

All configuration is managed at runtime through the Admin UI (`/config`). On first boot, some values are seeded from environment variables. After that, changes are made in the UI — most without a restart. Every change needs editing unlocked with a second-factor code; until 2FA is set up (Services page), the configuration is read-only.

## How It Works

```
Environment variables (.env) ──seed on first boot──> PostgreSQL (settings table)
                                                           │
                                                     ETS cache (fast reads)
                                                           │
                                                     Admin UI (edit at runtime, 2FA elevation)
                                                           │
                                                     PubSub broadcast (live updates)

Secret settings (tokens, keys) ──Config page──> OpenBao  (the settings row keeps no value)
```

- Settings are stored in the `settings` table with key, value, type, category, and sensitivity flag
- On startup, all settings are loaded into an ETS table for O(1) reads
- Changes via the Admin UI update both the database and ETS cache immediately
- PubSub broadcasts notify all subscribers of changes in real-time
- A secret setting's value is written to OpenBao, never to the table or the cache

## Required Environment Variables

These must be set in `.env` before first boot:

| Variable | Description |
|---|---|
| `DATABASE_OWNER_USERNAME` | PostgreSQL owner role — runs migrations, in the `migrate` service only |
| `DATABASE_OWNER_PASSWORD` | The owner's password |
| `DATABASE_USERNAME` | PostgreSQL application role the app connects as — never the owner |
| `DATABASE_PASSWORD` | The application role's password |
| `SECRET_KEY_BASE` | Phoenix session secret, at least 64 bytes (`openssl rand -base64 48`) |
| `ADMIN_PASSWORD` | The first admin password: the first login stores its hash, and the variable is ignored afterwards |
| `CLUSTER_COOKIE` | Erlang distribution cookie (`openssl rand -base64 32`) |

Optional:

| Variable | Description |
|---|---|
| `TELEGRAM_CHAT_ID` | Seeds `telegram.chat_id` at the first start; optional, it can be set on the Config page |
| `OPENBAO_UNSEAL_DIR` | Host directory holding OpenBao's unseal key (default `./openbao/unseal`) |

Then set **`telegram.chat_id`** and **`telegram.owner_user_id`** (your
Telegram user ID) on the Config page: only that user's messages in that chat
are answered, and with either blank nothing is.

## LLM Providers

At least one LLM provider is required. The Gemini (free tier available) and
Anthropic API keys are entered on the Config page (`llm.gemini_api_key`,
`llm.anthropic_api_key`) and kept in OpenBao; local models are enabled in `.env`:

| Variable | Description |
|---|---|
| `OLLAMA_ENABLED=true` + `OLLAMA_HOST` | Local Ollama instance |
| `LMSTUDIO_ENABLED=true` + `LMSTUDIO_HOST` | Local LM Studio instance |

After first boot, providers are managed from **Admin > LLM**. You can add, remove, reorder priorities, enable/disable providers, and configure per-provider inference options (e.g., `num_ctx`, `temperature`) — stored in an `options` JSON column on each provider. The LLM page shows a dynamic options form that adapts to the provider type. A cloud provider seeded before its API key was set starts disabled: enable it there once the key is entered. The `embedding.provider` setting is configured via a dropdown of enabled provider names on the Config page.

## Discord (Optional)

Discord is **not** configured by environment variable. Set these in
**Admin > Config** and restart the container:

| Setting | Description |
|---|---|
| `discord.enabled` | Enable the Discord gateway |
| `discord.bot_token` | Discord bot token (kept in OpenBao) |
| `discord.channel_id` | Command channel ID, set in the admin UI; a message never makes its channel the owner |
| `discord.owner_user_id` | The owner's Discord user ID: only their messages in the channel are answered; blank answers nothing |
| `discord.node` | In a cluster, the single node that runs the bot. Blank means any node |

## Config Categories

Settings are organized by category in the Admin UI:

| Category | Examples |
|---|---|
| `telegram`, `discord` | Bot tokens, gateway owners (chat/channel and user IDs), node assignment |
| `skills` | RSS thresholds, fetch timeouts, item limits |
| `shell` | Command allowlist, exact-match list, blocklist, timeout, output cap |
| `prompts` | System prompts, context templates |
| `llm` | Provider-specific settings, API keys |
| `identity` | Agent name, base prompt |
| `mcp` | MCP key (Generate / Revoke; only its fingerprint is stored) |
| `github` | Access token, webhook secret, default repo, watched branches |
| `auth` | Login rate limits, 2FA state |

## Secret Values

API keys, bot tokens, OAuth secrets and webhook secrets are declared secret
settings: their values are kept in OpenBao, and the Config page shows when
each was set, never the value. An empty input keeps the value; a new one
replaces it. They are never seeded from the environment. A new setting named
like a credential (`api_key`, `token`, `password` or `secret` in its key) is
refused unless it is a declared secret setting.

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

`Config.get/2` raises on a declared secret setting: a secret's value is not
read from the configuration cache.

See the full list of bootstrap variables in [`.env.example`](https://github.com/thatsme/AlexClaw/blob/main/.env.example).

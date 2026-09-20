# Environment Variables

All variables are set in the `.env` file. Values are seeded to the database on first boot — after that, changes are made via the Admin UI.

## Required

| Variable | Description |
|---|---|
| `DATABASE_PASSWORD` | PostgreSQL password |
| `SECRET_KEY_BASE` | Phoenix session/encryption secret (min 64 bytes) |
| `ADMIN_PASSWORD` | Web UI login password |
| `TELEGRAM_BOT_TOKEN` | Telegram bot token from @BotFather |
| `TELEGRAM_CHAT_ID` | Your Telegram chat ID |

One gateway is required: Telegram or Discord. Both are read only when the
matching setting is empty, and exist so an instance with nothing in its
database can still be asked for a 2FA code.

| Variable | Description |
|---|---|
| `DISCORD_BOT_TOKEN` | Discord bot token from the Developer Portal |
| `DISCORD_CHANNEL_ID` | Discord channel ID for commands and prompts |

## LLM Providers (at least one)

| Variable | Description |
|---|---|
| `GEMINI_API_KEY` | Google Gemini API key (free tier available) |
| `ANTHROPIC_API_KEY` | Anthropic Claude API key |
| `OLLAMA_ENABLED` | `true` to enable Ollama |
| `OLLAMA_HOST` | Ollama API URL (e.g., `http://host.docker.internal:11434`) |
| `LMSTUDIO_ENABLED` | `true` to enable LM Studio |
| `LMSTUDIO_HOST` | LM Studio API URL (e.g., `http://host.docker.internal:1234`) |

## Discord (optional)

Discord has no environment variables. Set `discord.enabled`,
`discord.bot_token` and `discord.channel_id` in **Admin > Config** and restart
the container.

## Database

| Variable | Default | Description |
|---|---|---|
| `DATABASE_HOSTNAME` | — | PostgreSQL host (required) |
| `DATABASE_USERNAME` | — | PostgreSQL role (required) |
| `DATABASE_PASSWORD` | — | PostgreSQL password (required) |
| `POOL_SIZE` | `10` | Connection pool size |

The database name is set by the compose file, not by an environment variable.

## Application

| Variable | Default | Description |
|---|---|---|
| `SECRET_KEY_BASE` | — | Session and encryption key (required) |
| `ADMIN_PASSWORD` | — | Admin UI password (required) |
| `SKILLS_DIR` | `/app/skills` | Where dynamic skill files live |
| `ADMIN_PORT` | `5001` | Host port the admin UI is published on |

## Clustering

| Variable | Default | Description |
|---|---|---|
| `NODE_NAME` | `alexclaw@node1.local` | BEAM node name |
| `CLUSTER_COOKIE` | — | Shared cluster authentication cookie |

## Backups

| Variable | Default | Description |
|---|---|---|
| `BACKUP_DIR` | `./backups` | Host path for database backups |

## Post-Boot Provider Options

After first boot, per-provider inference options (e.g., `num_ctx`, `temperature`, `top_p`) are managed exclusively via the Admin UI on the LLM Providers page. These are stored in an `options` JSON column on the `llm_providers` table and are not configurable through environment variables.

## See Also

The full list with defaults is in [`.env.example`](https://github.com/thatsme/AlexClaw/blob/main/.env.example).

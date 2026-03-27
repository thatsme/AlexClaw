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

| Variable | Description |
|---|---|
| `DISCORD_ENABLED` | `true` to enable Discord gateway |
| `DISCORD_BOT_TOKEN` | Discord bot token |
| `DISCORD_CHANNEL_ID` | Command channel ID |
| `DISCORD_GUILD_ID` | Server (guild) ID |

## Database

| Variable | Default | Description |
|---|---|---|
| `DATABASE_HOST` | `db` | PostgreSQL host |
| `DATABASE_PORT` | `5432` | PostgreSQL port |
| `DATABASE_NAME` | `alex_claw` | Database name |
| `DATABASE_USER` | `postgres` | Database user |
| `DATABASE_PASSWORD` | — | Database password (required) |
| `DATABASE_POOL_SIZE` | `10` | Connection pool size |

## Application

| Variable | Default | Description |
|---|---|---|
| `PHX_HOST` | `localhost` | Hostname for URL generation |
| `PORT` | `5001` | HTTP port |
| `SECRET_KEY_BASE` | — | Session and encryption key (required) |

## Clustering

| Variable | Default | Description |
|---|---|---|
| `NODE_NAME` | `alexclaw@node1.local` | BEAM node name |
| `CLUSTER_COOKIE` | — | Shared cluster authentication cookie |

## Backups

| Variable | Default | Description |
|---|---|---|
| `BACKUP_DIR` | `./backups` | Host path for database backups |

## See Also

The full list with defaults is in [`.env.example`](https://github.com/thatsme/AlexClaw/blob/main/.env.example).

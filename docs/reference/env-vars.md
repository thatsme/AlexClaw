# Environment Variables

All variables are set in the `.env` file. The ones marked *Seeded* are copied into the database on first boot and are managed in **Admin > Config** afterwards; changing them in `.env` later has no effect. All others are read from the environment at every start.

## Required

| Variable | Description |
|---|---|
| `DATABASE_PASSWORD` | PostgreSQL password |
| `SECRET_KEY_BASE` | Phoenix session/encryption secret (min 64 bytes) |
| `ADMIN_PASSWORD` | Web UI login password |
| `TELEGRAM_BOT_TOKEN` | *Seeded.* Telegram bot token from @BotFather |

## Telegram

| Variable | Description |
|---|---|
| `TELEGRAM_CHAT_ID` | *Seeded.* Optional: when empty, the chat is detected from the first message sent to the bot |

## LLM Providers (at least one)

| Variable | Description |
|---|---|
| `GEMINI_API_KEY` | *Seeded.* Google Gemini API key (free tier available) |
| `ANTHROPIC_API_KEY` | *Seeded.* Anthropic Claude API key |
| `OLLAMA_ENABLED` | *Seeded.* `true` to enable Ollama |
| `OLLAMA_HOST` | *Seeded.* Ollama API URL (e.g., `http://host.docker.internal:11434`) |
| `OLLAMA_MODEL` | *Seeded.* Default Ollama model (default `llama3.2`) |
| `LMSTUDIO_ENABLED` | *Seeded.* `true` to enable LM Studio |
| `LMSTUDIO_HOST` | *Seeded.* LM Studio API URL (e.g., `http://host.docker.internal:1234`) |
| `LMSTUDIO_MODEL` | *Seeded.* Default LM Studio model (default `qwen2.5-14b-instruct`) |

## Google OAuth (optional)

| Variable | Description |
|---|---|
| `GOOGLE_OAUTH_CLIENT_ID` | *Seeded.* OAuth client ID |
| `GOOGLE_OAUTH_CLIENT_SECRET` | *Seeded.* OAuth client secret |
| `GOOGLE_OAUTH_REFRESH_TOKEN` | *Seeded.* Refresh token, if one was obtained outside AlexClaw |
| `GOOGLE_OAUTH_REDIRECT_URI` | *Seeded.* OAuth redirect URI |

## Web Automator (optional)

| Variable | Default | Description |
|---|---|---|
| `COMPOSE_PROFILES` | — | Docker Compose's own variable, not read by AlexClaw. `web-automation` makes `docker compose up` build and start the sidecar with the rest of the stack |
| `WEB_AUTOMATOR_ENABLED` | `false` | *Seeded.* Lets AlexClaw call the web-automator sidecar |
| `WEB_AUTOMATOR_HOST` | `http://web-automator:6900` | *Seeded.* The sidecar's API URL |
| `WEB_AUTOMATOR_TOKEN` | — | Shared bearer token, read by both AlexClaw and the sidecar at start; not stored. Without it the sidecar refuses every request and AlexClaw sends none. Generate with `openssl rand -hex 32` |

## OpenBao

| Variable | Default | Description |
|---|---|---|
| `OPENBAO_UNSEAL_DIR` | `./openbao/unseal` | Host directory holding `key`, OpenBao's 32-byte unseal key, mounted read-only into the `openbao` service only. It must exist before the first start. See [OpenBao](../architecture/openbao.md) |

`OPENBAO_ADDR` and `OPENBAO_BOOTSTRAP_DIR` are set by the compose file.

## Discord (optional)

Discord has no environment variables. Set `discord.enabled`,
`discord.bot_token` and `discord.channel_id` in **Admin > Config** and restart
the container.

## Database

| Variable | Default | Description |
|---|---|---|
| `DATABASE_HOSTNAME` | — | PostgreSQL host (required) |
| `DATABASE_USERNAME` | — | PostgreSQL application role the app connects as (required). Never the owner: the app refuses to start as a role that is a superuser, can create roles or databases, or owns a table |
| `DATABASE_PASSWORD` | — | The application role's password (required) |
| `DATABASE_OWNER_USERNAME` | `alexclaw` | PostgreSQL owner role. Seen only by the `migrate` service and the database container |
| `DATABASE_OWNER_PASSWORD` | — | The owner's password (required by the `migrate` service) |
| `POOL_SIZE` | `10` | Connection pool size |

The database name is set by the compose file, not by an environment variable.

## Application

| Variable | Default | Description |
|---|---|---|
| `SECRET_KEY_BASE` | — | Session and encryption key (required) |
| `ADMIN_PASSWORD` | — | Admin UI password (required) |
| `SKILLS_DIR` | `/app/skills` | Where dynamic skill files live |
| `ADMIN_PORT` | `5001` | Host port the admin UI is published on |
| `ADMIN_BIND` | `127.0.0.1` | Host interface the admin UI is published on. `0.0.0.0` for every interface; see [Reverse Proxy](../deployment/reverse-proxy.md) before doing so |
| `PHX_HOST` | — | Public host name behind a reverse proxy; adds `https://<host>` to the accepted LiveView origins |
| `CHECK_ORIGIN` | — | Comma-separated LiveView origins; replaces the default list (both loopback spellings on `ADMIN_PORT`, plus `PHX_HOST`) |
| `TOTP_ISSUER` | `AlexClaw` | Issuer name shown in the authenticator app |

## Clustering

| Variable | Default | Description |
|---|---|---|
| `NODE_NAME` | `alexclaw@node1.local` | BEAM node name |
| `CLUSTER_COOKIE` | — | Shared cluster authentication cookie (required; the node refuses to start without it) |

## Backups

| Variable | Default | Description |
|---|---|---|
| `BACKUP_DIR` | `./backups` | Host path for database backups |

## Post-Boot Provider Options

After first boot, per-provider inference options (e.g., `num_ctx`, `temperature`, `top_p`) are managed exclusively via the Admin UI on the LLM Providers page. These are stored in an `options` JSON column on the `llm_providers` table and are not configurable through environment variables.

## See Also

The full list with defaults is in [`.env.example`](https://github.com/thatsme/AlexClaw/blob/main/.env.example).

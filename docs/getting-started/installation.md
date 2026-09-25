# Installation

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) and [Docker Compose](https://docs.docker.com/compose/install/) v2+
- A Telegram bot token (from [@BotFather](https://t.me/BotFather))
- At least one LLM provider API key (or a local model via Ollama/LM Studio)

## Quick Start

```bash
git clone https://github.com/thatsme/AlexClaw.git
cd AlexClaw
cp .env.example .env
```

Edit `.env` with your settings:

```bash
# Required
DATABASE_PASSWORD=your_secure_db_password
SECRET_KEY_BASE=$(openssl rand -base64 48)   # at least 64 bytes; shorter is refused
ADMIN_PASSWORD=your_admin_password
TELEGRAM_CHAT_ID=your_chat_id
```

At least one LLM provider is required. The Gemini (free tier available) and
Anthropic API keys are entered on the Config page after the first start, and
kept in OpenBao.

Start the stack:

```bash
docker compose up -d
```

!!! tip "First boot"
    On first start, AlexClaw runs database migrations, seeds default LLM providers, and loads configuration from environment variables into the database. Subsequent restarts use the database values — changes are made via the Admin UI.

## Verify

1. Open [http://localhost:5001](http://localhost:5001) and log in with your `ADMIN_PASSWORD`
2. Send `/ping` to your Telegram bot — you should get `pong`
3. Check `GET /health` returns `{"status":"ok"}`

## Services

The `docker-compose.yml` starts the database, a one-shot `migrate` job, and the application; the web automator on request:

| Service | Container Name | Description | Port |
|---|---|---|---|
| `alexclaw-prod` | `alexclaw-prod` | Main application (Elixir release) | 5001 |
| `db-prod` | `alexclaw-db-prod` | PostgreSQL 17 with pgvector | — (internal only) |
| `migrate` | `alexclaw-migrate` | Applies migrations and exits | — |
| `web-automator` | — | Playwright sidecar for browser automation, opt-in. Set `WEB_AUTOMATOR_ENABLED=true` in `.env` (the shared token is generated at the first start), then `docker compose --profile web-automation up -d`. See [INSTALLATION.md](https://github.com/thatsme/AlexClaw/blob/main/INSTALLATION.md#web-automator-sidecar-optional) | 6080 (noVNC, loopback) |

## Building from Source

If you modify the code, rebuild:

```bash
docker compose up --build --no-deps -d alexclaw-prod
```

!!! warning "Don't recreate the database"
    Always use `--no-deps` when rebuilding the app to avoid recreating the `db-prod` container and losing data.

## Detailed Setup

For Telegram bot creation, local model setup (Ollama/LM Studio), and advanced configuration, see the full [INSTALLATION.md](https://github.com/thatsme/AlexClaw/blob/main/INSTALLATION.md) in the repository.

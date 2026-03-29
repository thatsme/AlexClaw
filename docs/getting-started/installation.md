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
SECRET_KEY_BASE=$(mix phx.gen.secret)   # or use: openssl rand -base64 64
ADMIN_PASSWORD=your_admin_password
TELEGRAM_BOT_TOKEN=your_bot_token
TELEGRAM_CHAT_ID=your_chat_id

# At least one LLM provider
GEMINI_API_KEY=your_gemini_key          # Free tier available
```

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

The `docker-compose.yml` starts three services:

| Service | Container Name | Description | Port |
|---|---|---|---|
| `alexclaw-prod` | `alexclaw-prod` | Main application (Elixir release) | 5001 |
| `db-prod` | `alexclaw-db-prod` | PostgreSQL 17 with pgvector | 5432 |
| `web-automator` | — | Playwright sidecar for browser automation (optional) | 8000 |

## Building from Source

If you modify the code, rebuild:

```bash
docker compose up --build --no-deps -d alexclaw-prod
```

!!! warning "Don't recreate the database"
    Always use `--no-deps` when rebuilding the app to avoid recreating the `db-prod` container and losing data.

## Detailed Setup

For Telegram bot creation, local model setup (Ollama/LM Studio), and advanced configuration, see the full [INSTALLATION.md](https://github.com/thatsme/AlexClaw/blob/main/INSTALLATION.md) in the repository.

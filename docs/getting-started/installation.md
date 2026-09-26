# Installation

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) and [Docker Compose](https://docs.docker.com/compose/install/) v2+
- A Telegram bot token (from [@BotFather](https://t.me/BotFather))
- At least one LLM provider API key (or a local model via Ollama/LM Studio)
- An authenticator app (TOTP): the configuration cannot be changed without a second factor

## Quick Start

```bash
git clone https://github.com/thatsme/AlexClaw.git
cd AlexClaw
cp .env.example .env
```

Edit `.env` with your settings:

```bash
# Required — generate each value and paste it in:
#   openssl rand -hex 32      (each database password, two different values)
#   openssl rand -base64 48   (SECRET_KEY_BASE, at least 64 bytes)
#   openssl rand -base64 32   (CLUSTER_COOKIE)
DATABASE_OWNER_PASSWORD=...
DATABASE_USERNAME=alexclaw_app
DATABASE_PASSWORD=...
SECRET_KEY_BASE=...
CLUSTER_COOKIE=...
ADMIN_PASSWORD=your_admin_password
```

At least one LLM provider is required. The Gemini (free tier available) and
Anthropic API keys are entered on the Config page after the first start, and
kept in OpenBao.

Make OpenBao's unseal key, start the stack, and initialise OpenBao once, at
a terminal:

```bash
mkdir -p openbao/unseal
head -c 32 /dev/urandom > openbao/unseal/key && chmod 0440 openbao/unseal/key
docker compose up -d
docker compose run --rm openbao-init
```

On Linux, also `sudo chown 100 openbao/unseal/key` before starting. The first
`docker compose up -d` leaves `openbao-init` exited, saying OpenBao is not
initialised; the second command initialises it, prints the recovery key once
and waits until `SAVED` is typed. Losing the key file loses every secret:
keep a copy offline, with the recovery key. Details:
[OpenBao](../architecture/openbao.md).

!!! tip "First boot"
    On first start, the `migrate` job runs the database migrations, and AlexClaw seeds default LLM providers and loads configuration from environment variables into the database. Subsequent restarts use the database values — changes are made via the Admin UI. The Gemini and Claude providers are seeded disabled, since no key is set yet.

## Verify

1. Open [http://localhost:5001](http://localhost:5001) and log in with `ADMIN_PASSWORD`
2. Set up 2FA (Services page) and store the recovery codes; until then the configuration is read-only
3. Unlock editing with a code and enter the Telegram bot token, `telegram.chat_id`, `telegram.owner_user_id` and an LLM API key on the Config page; enable the providers that use the key on the LLM page
4. Send `/ping` to the bot — the answer is `pong`
5. `GET /health` returns `{"status":"ok"}`

## Services

The `docker-compose.yml` starts the database, a one-shot `migrate` job, the application, OpenBao with its one-shot `openbao-init`, and the one-shot `automator-token-init`; the web automator on request:

| Service | Container Name | Description | Port |
|---|---|---|---|
| `alexclaw-prod` | `alexclaw-prod` | Main application (Elixir release) | 5001 (loopback) |
| `db-prod` | `alexclaw-db-prod` | PostgreSQL 17 with pgvector | — (internal only) |
| `migrate` | `alexclaw-migrate` | Applies migrations and exits | — |
| `openbao` | — | OpenBao 2.6, pinned by digest. Holds every secret | — (never published) |
| `openbao-init` | — | Makes OpenBao's TLS certificate at every start; initialises OpenBao once, at a terminal | — |
| `automator-token-init` | — | Generates the web automator's token once, and exits | — |
| `web-automator` | — | Playwright sidecar for browser automation, opt-in. Set `WEB_AUTOMATOR_ENABLED=true` in `.env` (the shared token is generated at the first start), then `docker compose --profile web-automation up -d`. See [INSTALLATION.md](https://github.com/thatsme/AlexClaw/blob/main/INSTALLATION.md#web-automator-sidecar-optional) | 6080 (noVNC, loopback) |

An on-demand `openbao-backup` service (compose profile `backup`) takes OpenBao snapshots; it is never started by `docker compose up`. See [OpenBao](../architecture/openbao.md#backing-up-and-restoring-openbao).

## Building from Source

After code changes, rebuild and start the stack:

```bash
docker compose up --build -d
```

The `migrate` job runs first, and the application starts after it. Volumes
are kept; only `docker compose down -v` removes them — the database and every
secret in OpenBao with it.

## Detailed Setup

For Telegram bot creation, local model setup (Ollama/LM Studio), and advanced configuration, see the full [INSTALLATION.md](https://github.com/thatsme/AlexClaw/blob/main/INSTALLATION.md) in the repository.

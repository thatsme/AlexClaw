# Installation Guide

## System Requirements

- **Docker** and **Docker Compose** (v2)
- **2 GB RAM minimum** (PostgreSQL + pgvector + Elixir app)
- ~1 GB disk for images + database
- A **Telegram bot token** from [@BotFather](https://t.me/BotFather)
- At least one **LLM provider** — the fastest free path is a [Gemini API key](https://ai.google.dev/) (no credit card, takes 2 minutes)

---

## Setup

### 1. Clone and create your `.env`

```bash
git clone https://github.com/thatsme/AlexClaw.git
cd AlexClaw
cp .env.example .env
```

Your `.env` file will look like this:

```bash
# === Required ===
DATABASE_USERNAME=alexclaw
DATABASE_PASSWORD=changeme
SECRET_KEY_BASE=generate_with_openssl_rand_base64_48
ADMIN_PASSWORD=changeme

# === Telegram ===
TELEGRAM_BOT_TOKEN=your-bot-token-from-botfather
TELEGRAM_CHAT_ID=              # optional — auto-detected on first message

# === LLM Providers (at least one required) ===
GEMINI_API_KEY=
ANTHROPIC_API_KEY=

# === Local Models (optional) ===
# OLLAMA_ENABLED=true
# OLLAMA_HOST=http://host.docker.internal:11434
# OLLAMA_MODEL=llama3.2

# LMSTUDIO_ENABLED=true
# LMSTUDIO_HOST=http://host.docker.internal:1234
# LMSTUDIO_MODEL=qwen2.5-14b-instruct

# === Google OAuth (optional — for Calendar, Keep skills) ===
# GOOGLE_OAUTH_CLIENT_ID=
# GOOGLE_OAUTH_CLIENT_SECRET=
# GOOGLE_OAUTH_REFRESH_TOKEN=

# === Clustering (optional — multi-node) ===
# NODE_NAME=alexclaw@node1.local
# CLUSTER_COOKIE=generate_a_random_secret

# === Advanced ===
# ADMIN_PORT=5001
```

### 2. Generate secrets

Run these two commands **in your terminal** and paste each output into `.env`:

```bash
# Generate DATABASE_PASSWORD — copy the output into .env
openssl rand -hex 32

# Generate SECRET_KEY_BASE — copy the output into .env
openssl rand -base64 48
```

Then fill in the remaining values:

| Variable | What to do |
|---|---|
| `DATABASE_PASSWORD` | Paste the output of the first `openssl` command |
| `SECRET_KEY_BASE` | Paste the output of the second `openssl` command |
| `ADMIN_PASSWORD` | Choose a strong password for the web admin UI |
| `DATABASE_USERNAME` | Leave as `alexclaw` (default) unless you have a reason to change it |
| `TELEGRAM_BOT_TOKEN` | From @BotFather (see [Getting Your Bot Token](#getting-your-telegram-bot-token) below) |
| `TELEGRAM_CHAT_ID` | **Optional** — leave empty and AlexClaw will auto-detect it when you send the bot its first message. Or set it manually (see [Getting Your Chat ID](#getting-your-telegram-chat-id) below) |
| `GEMINI_API_KEY` | Free key from [ai.google.dev](https://ai.google.dev/) — gives you `light` and `medium` LLM tiers with no credit card |

### 3. Start

```bash
docker compose up -d
```

On first boot, AlexClaw will:
1. Create the PostgreSQL database with pgvector
2. Run all migrations
3. Seed default configuration from your `.env` values
4. Seed example workflows and RSS feeds (Tech News Digest, Web Research)
5. Start the application

This takes 30–60 seconds on first run. You can watch progress with:

```bash
docker compose logs -f alexclaw-prod
```

When you see `Running AlexClawWeb.Endpoint at 0.0.0.0:5001`, it's ready.

### 4. Log in

Open [http://localhost:5001](http://localhost:5001) and log in with your `ADMIN_PASSWORD`.

You should see the Dashboard with the version number and example workflows listed under Workflows.

> **macOS users:** Port 5001 is used by AirPlay Receiver by default. If you get a port conflict, either disable AirPlay Receiver (System Settings > General > AirDrop & Handoff) or set `ADMIN_PORT=5002` in your `.env` and restart.

### 5. Verify Telegram

Send `/ping` to your Telegram bot. You should get `pong` back.

If you left `TELEGRAM_CHAT_ID` empty, this first message also triggers auto-detection — AlexClaw saves your chat ID automatically. No further setup needed.

If the bot doesn't respond, see [Troubleshooting > Bot not responding](#bot-not-responding).

Send `/help` to see all available commands.

---

## Getting Your Telegram Bot Token

1. Open Telegram and search for [@BotFather](https://t.me/BotFather)
2. Send `/newbot`
3. Choose a name and username for your bot
4. BotFather will give you a token like `123456789:ABCdefGHIjklMNOpqrsTUVwxyz`
5. Copy this token to `TELEGRAM_BOT_TOKEN` in your `.env`

## Getting Your Telegram Chat ID

**Easiest way:** Leave `TELEGRAM_CHAT_ID` empty in your `.env` and just start AlexClaw. Send any message to your bot — AlexClaw auto-detects your chat ID and saves it. Done.

**Manual method** (if auto-detect doesn't work or you need a specific chat ID):

1. **Send any message** to your bot first (required — the next step returns empty otherwise)
2. Open this URL in your browser (replace `YOUR_TOKEN` with your actual bot token):
   ```
   https://api.telegram.org/botYOUR_TOKEN/getUpdates
   ```
3. Look for `"chat":{"id":123456789}` in the JSON response
4. Copy the numeric ID to `TELEGRAM_CHAT_ID` in your `.env` and restart

> **If the response is empty** (`"result":[]`), make sure you've sent the bot at least one message first. If you previously set a webhook on the bot, remove it with:
> ```
> https://api.telegram.org/botYOUR_TOKEN/deleteWebhook
> ```
> Then send a message and try `getUpdates` again.

---

## LLM Provider Setup

AlexClaw needs at least one LLM provider. The router automatically selects the cheapest available model for each task.

| Provider | Tier | Cost | Setup |
|---|---|---|---|
| Gemini Flash | light | Free (250 req/day) | Set `GEMINI_API_KEY` |
| Gemini Pro | medium | Free (50 req/day) | Set `GEMINI_API_KEY` |
| Claude Haiku | light | Paid | Set `ANTHROPIC_API_KEY` |
| Claude Sonnet | medium | Paid | Set `ANTHROPIC_API_KEY` |
| Claude Opus | heavy | Paid | Set `ANTHROPIC_API_KEY` |
| Ollama | local | Free (your hardware) | See Local Models below |
| LM Studio | local | Free (your hardware) | See Local Models below |

**Recommended first setup:** Get a free [Gemini API key](https://ai.google.dev/). No credit card, takes 2 minutes, and gives you both `light` and `medium` tiers.

All limits are configurable at runtime from Admin > Config.

---

## Local Models (Optional)

Local models run on your own hardware — no API keys, no costs, full privacy. The right model depends on your machine:

| VRAM | Suggested size | Examples |
|---|---|---|
| 4 GB | 3B–7B params | `llama3.2`, `phi-3-mini`, `gemma2:2b` |
| 8 GB | 7B–14B params | `llama3.1:8b`, `qwen2.5:14b`, `mistral` |
| 16 GB+ | 14B–32B params | `qwen2.5:32b`, `deepseek-coder-v2` |
| CPU only (no GPU) | 1B–3B params | `llama3.2:1b`, `phi-3-mini` (slow but works) |

These are rough guidelines — actual fit depends on quantization, context length, and other factors. Start small, try it, and go bigger if your hardware handles it.

### Ollama

1. Install [Ollama](https://ollama.ai/) on your host machine
2. Pull a model that fits your hardware: `ollama pull llama3.2`
3. Verify the exact model name with `ollama list` — use the name from the first column
4. Add to your `.env`:
   ```
   OLLAMA_ENABLED=true
   OLLAMA_HOST=http://host.docker.internal:11434
   OLLAMA_MODEL=llama3.2
   ```
5. Restart: `docker compose restart alexclaw-prod`

### LM Studio

1. Install [LM Studio](https://lmstudio.ai/) on your host machine
2. Browse and download a model that fits your hardware (LM Studio shows compatibility)
3. Load the model and start the local server (Developer tab > Start Server)
4. Use the model identifier shown in LM Studio's server log — that exact string goes in `.env`
5. Add to your `.env`:
   ```
   LMSTUDIO_ENABLED=true
   LMSTUDIO_HOST=http://host.docker.internal:1234
   LMSTUDIO_MODEL=your-model-name
   ```
6. Restart: `docker compose restart alexclaw-prod`

> `host.docker.internal` allows the Docker container to reach services on your host machine. This works automatically on Docker Desktop (macOS/Windows). For Linux, see the [VPS section](#running-on-a-vps--cloud-server) below.

---

## Google Calendar Setup (Optional)

AlexClaw can fetch your upcoming events from Google Calendar. This requires a one-time OAuth2 setup.

### 1. Create Google Cloud credentials

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create a new project (or use an existing one)
3. Enable the **Google Calendar API**: APIs & Services > Library > search "Google Calendar API" > Enable
4. Create OAuth credentials: APIs & Services > Credentials > Create Credentials > OAuth client ID
   - Application type: **Desktop app**
   - Name: `AlexClaw`
5. Copy the **Client ID** and **Client Secret**

### 2. Get a refresh token

Run this in your browser to start the OAuth flow (replace `YOUR_CLIENT_ID`):

```
https://accounts.google.com/o/oauth2/v2/auth?client_id=YOUR_CLIENT_ID&redirect_uri=urn:ietf:wg:oauth:2.0:oob&response_type=code&scope=https://www.googleapis.com/auth/calendar.readonly&access_type=offline&prompt=consent
```

> If `urn:ietf:wg:oauth:2.0:oob` doesn't work (Google deprecated it for some projects), set the redirect URI to `http://localhost` and copy the `code` parameter from the URL bar after authorization.

After authorizing, you'll get an authorization code. Exchange it for a refresh token:

```bash
curl -s -X POST https://oauth2.googleapis.com/token \
  -d "code=YOUR_AUTH_CODE" \
  -d "client_id=YOUR_CLIENT_ID" \
  -d "client_secret=YOUR_CLIENT_SECRET" \
  -d "redirect_uri=urn:ietf:wg:oauth:2.0:oob" \
  -d "grant_type=authorization_code"
```

Copy the `refresh_token` from the response.

### 3. Configure AlexClaw

Add to your `.env`:

```
GOOGLE_OAUTH_CLIENT_ID=your-client-id
GOOGLE_OAUTH_CLIENT_SECRET=your-client-secret
GOOGLE_OAUTH_REFRESH_TOKEN=your-refresh-token
```

Or set them at runtime in Admin > Config under the `google` category.

Restart: `docker compose restart alexclaw-prod`

### 4. Use in workflows

Create a workflow step with skill `google_calendar`. Config options:

| Key | Default | Description |
|---|---|---|
| `calendar_id` | `primary` | Which calendar to query |
| `days` | `1` | How many days ahead to fetch |
| `max_results` | `20` | Maximum events to return |

Example: a "Daily Briefing" workflow could use `google_calendar` as step 1, then `llm_transform` to summarize, then `telegram_notify` to deliver.

---

## Google Tasks Setup (Optional)

Google Tasks uses the same OAuth credentials as Google Calendar. If you've already set up Google Calendar, Tasks work automatically — no additional configuration needed.

The only difference is the API scope. If you set up OAuth before Tasks support was added, you may need to re-authorize with the additional scope `https://www.googleapis.com/auth/tasks`. The easiest way is to use the Telegram-based OAuth flow:

1. Send `/google auth` to your bot
2. Follow the link and authorize both Calendar and Tasks scopes
3. Send the authorization code back to the bot

### Telegram commands

| Command | Description |
|---|---|
| `/tasks` | List your Google Tasks |
| `/tasklists` | List your task lists by name |
| `/task add Buy groceries` | Add a new task |

Tasks can also be used as a workflow step with the `google_tasks` skill. You can target a specific list by name in the config (e.g., `"task_list": "Shopping"`) — the skill resolves names to IDs automatically.

---

## Discord Setup (Optional)

AlexClaw supports Discord as a full bidirectional gateway — you can use Discord instead of (or alongside) Telegram for all commands and notifications. No `.env` changes needed — configure entirely from the admin UI.

### 1. Create a Discord Application

1. Go to [Discord Developer Portal](https://discord.com/developers/applications)
2. Click **New Application**, give it a name (e.g. "AlexClaw")
3. Go to the **Bot** tab
4. Click **Reset Token** and copy the token — you'll need it in step 4

### 2. Enable Privileged Intents

Still on the **Bot** tab, scroll down to **Privileged Gateway Intents** and enable:

- **Message Content Intent** — required for the bot to read message text

### 3. Invite the Bot to Your Server

Build this URL (replace `YOUR_APPLICATION_ID` with the ID from **General Information**):

```
https://discord.com/api/oauth2/authorize?client_id=YOUR_APPLICATION_ID&permissions=101376&scope=bot
```

Open it in your browser, select your server, and authorize. The bot appears in the member list.

The permissions included (101376) are: View Channels, Send Messages, Attach Files, Read Message History.

### 4. Configure AlexClaw

1. Open **Admin > Config** in AlexClaw
2. Expand the **discord** section
3. Set `discord.enabled` to `true`
4. Paste your bot token into `discord.bot_token`
5. Restart the container: `docker compose restart alexclaw-prod`

The bot should appear online in Discord within a few seconds. `discord.channel_id` is auto-detected when you send the bot its first message — no need to set it manually.

### 5. Verify

Type `/ping` in any text channel where the bot has access. You should get `pong` back.

All commands listed under `/help` work identically in Discord and Telegram.

> **Note:** After changing the Discord bot token in Admin > Config, you must restart the container for the change to take effect (`docker compose restart alexclaw-prod`).

---

## Two-Factor Authentication (Optional)

AlexClaw supports TOTP-based 2FA for sensitive operations (workflow 2FA checkboxes).

### Setup via Telegram

1. Send `/setup 2fa` to your bot
2. You'll receive a QR code and a manual key
3. Scan the QR code with your authenticator app (Google Authenticator, Authy, etc.)
4. Send `/confirm 2fa <6-digit-code>` with a code from your authenticator

Once confirmed, workflows marked with "Require 2FA" will prompt for a code before execution.

---

## Web Automator Sidecar (Optional)

The web-automator is an optional Python/Playwright sidecar for browser automation — filling forms, clicking buttons, downloading files from sites that have no API.

### Enable

Add to your `.env`:

```bash
WEB_AUTOMATOR_ENABLED=true
WEB_AUTOMATOR_HOST=http://web-automator:6900
```

Start with the web-automator profile:

```bash
docker compose --profile web-automator up -d
```

### Verify

```bash
curl http://localhost:6900/health
```

The noVNC web UI for recording sessions is available at `http://localhost:6080`.

### Telegram Commands

| Command | Description |
|---|---|
| `/record <url>` | Start a recording session — opens a browser via noVNC |
| `/record stop <session_id>` | Stop recording, save captured actions as a resource |
| `/replay <resource_id>` | Replay a saved automation headlessly |
| `/automate <url>` | Quick scrape + screenshot of a URL |

### Example: Record and Replay a Form

**1. Record your interactions:**

Send `/record https://httpbin.org/forms/post` to your bot. You'll get a noVNC link — open it in your browser, fill out the form, then send `/record stop <session_id>`.

AlexClaw saves the captured actions as an automation resource with JSON like:

```json
{
  "steps": [
    {"action": "fill", "selector": "input[name=\"custname\"]", "value": "John"},
    {"action": "fill", "selector": "input[name=\"custemail\"]", "value": "john@example.com"},
    {"action": "select", "selector": "input[name=\"size\"][value=\"medium\"]", "value": "medium"},
    {"action": "check", "selector": "input[name=\"topping\"][value=\"cheese\"]", "value": "cheese"},
    {"action": "click", "selector": "button", "value": "Submit order"}
  ],
  "url": "https://httpbin.org/forms/post"
}
```

The recorder captures fills, selects (radio), checks (checkbox), and clicks with CSS selectors.

**2. Replay instantly:**

Send `/replay <resource_id>` to replay the automation headlessly and get the result.

**3. Build a workflow for scheduled replay:**

In Admin > Workflows, create a new workflow with two steps:

| Step | Skill | Config |
|---|---|---|
| 1. Submit Form | `web_automation` | `{"extra_steps": [{"action": "wait", "value": "2"}, {"action": "scrape_text"}]}` |
| 2. Deliver Result | `telegram_notify` | `{}` |

Then assign your automation resource to the workflow under Resources. The `extra_steps` in the step config are appended after the recorded steps — in this case, waiting for the page to load and scraping the result text.

Run with `/run <workflow_id>` or set a cron schedule for automated execution.

### Supported Actions

The player supports these actions in automation configs:

| Action | Description | Fields |
|---|---|---|
| `navigate` | Go to a URL | `url` |
| `fill` | Type into a text field | `selector`, `value` |
| `select` | Click a radio button or select dropdown option | `selector`, `value` |
| `check` | Check a checkbox | `selector`, `value` |
| `click` | Click a button or link | `selector` |
| `wait` | Wait for page to settle | `value` (seconds) |
| `keyboard` | Press a key | `value` (e.g. `"Enter"`) |
| `download` | Click and wait for file download | `selector` |
| `scrape` | Extract HTML tables from the page | `selector` (default: `"table"`) |
| `scrape_text` | Grab all visible text from the page | — |
| `screenshot` | Take a screenshot | `value` (name) |
| `evaluate` | Run arbitrary JavaScript | `value` (JS code) |
| `extract_grid` | Extract data from jqxGrid widgets | `selector`, `columns` |

Actions can be recorded via `/record` or written manually in the resource metadata JSON.

---

## Managing Example Workflows

On first boot, AlexClaw seeds example workflows:

- **Tech News Digest** — collects RSS feeds, scores relevance, summarizes, delivers to Telegram
- **Web Research** — searches the web for a topic, synthesizes a brief, delivers to Telegram

You can:
- Run them from Admin > Workflows (click "Run Now")
- Run them from Telegram: `/workflows` to list, `/run <id or name>` to execute
- Set a schedule (e.g. `0 8 * * *` for daily at 8am UTC)
- Edit steps, change prompts, add or remove feeds
- Create your own workflows from the Admin UI
- **Export** a workflow as a self-contained JSON file (click "Export" in the workflow actions) — includes all steps, configs, prompt templates, and full resource definitions
- **Import** a workflow from JSON (click "Import Workflow" at the top of the page) — resources are matched by name+URL if they already exist, or created automatically if they don't. Imported workflows are disabled by default with "(imported N)" appended to the name
- **Filter** the workflow list by typing in the search box under the Name column

To re-seed examples manually (if you deleted them):

```bash
make seed
```

Or if you don't have `make`:

```bash
docker compose exec alexclaw-prod bin/alex_claw rpc \
  'Path.wildcard("lib/alex_claw-*/priv/repo/seeds/example_workflows.exs") |> hd() |> Code.eval_file()'
```

---

## Clustering (Optional — Multi-Node)

AlexClaw supports running multiple instances connected via BEAM distribution. Each node runs independently with its own gateway connections and scheduler, sharing a single PostgreSQL database.

There are two Docker Compose files:

| File | Purpose |
|---|---|
| `docker-compose.yml` | **Single node** (default). One AlexClaw instance + DB + web-automator |
| `docker-compose_swarm.yml` | **Multi-node**. Two AlexClaw nodes + shared DB. Each node has its own port and node name |

### Single Node (default)

No extra config needed. Just `docker compose up -d` as described in Setup.

The default node name is `alexclaw@node1.local`. Override via `NODE_NAME` in `.env` if needed. Single-node mode ignores gateway node assignments — Telegram and Discord always start.

### Multi-Node (same machine)

```bash
docker compose -f docker-compose_swarm.yml up --build -d
```

This starts two nodes:
- **node1** — `alexclaw@node1.local` on `localhost:5001`
- **node2** — `alexclaw@node2.local` on `localhost:5002`

Both share the same database and auto-discover each other on boot. The Cluster admin page (Admin > Cluster) shows connected nodes.

To add more nodes, duplicate a node block in `docker-compose_swarm.yml` with a new hostname and port.

### Cross-Node Workflows

1. Create a workflow with `receive_from_workflow` as step 1 — this is the receiver
2. Create a workflow with `send_to_workflow` as a step — configure `target_node` and `target_workflow`
3. Run the sender workflow — data flows from one node to the other over BEAM distribution

### Node Assignment

Both workflows and gateways support node assignment — cluster-wide or pinned to a specific node. The database is always the source of truth.

**Workflows:** each workflow has a "Run on" dropdown (visible when clustering is active):
- **Cluster-wide** (default) — any node can run the scheduled workflow
- **Specific node** — only that node's scheduler picks it up

**Gateways (Telegram, Discord):** in Admin > Config, set `telegram.node` or `discord.node` to a node name. Only that node will connect the bot. Leave empty for cluster-wide (single-node default). This prevents multiple nodes from polling the same bot token — which causes API conflicts.

### Environment Variables

| Variable | Description | Example |
|---|---|---|
| `NODE_NAME` | BEAM node name. Use `.` for long names (recommended) | `alexclaw@node1.local` |
| `CLUSTER_COOKIE` | Shared secret for inter-node authentication | `your_random_secret` |

### Security

- `CLUSTER_COOKIE` is the authentication mechanism between nodes — treat it like `SECRET_KEY_BASE`
- EPMD (port 4369) must be reachable between nodes but should NOT be exposed publicly
- Use firewall rules or private networks to restrict inter-node traffic

---

## Running on a VPS / Cloud Server

AlexClaw is designed to run on a local machine, but works fine on a VPS too. Telegram polling is outbound-only, so no inbound ports are needed for the bot itself.

**Accessing the admin UI remotely** — the simplest option is an SSH tunnel:

```bash
ssh -L 5001:localhost:5001 your-vps
```

Then open `http://localhost:5001` on your local machine. No firewall changes needed.

If you want to expose the UI directly, put it behind a reverse proxy (nginx, Caddy, Traefik) with HTTPS. **Never expose port 5001 directly without TLS** — the admin password is sent in plain text over HTTP.

**Local models** (Ollama, LM Studio) are meant for local machines with a GPU. On a VPS, use cloud providers (Gemini, Anthropic) instead.

---

## Updating

AlexClaw is built from source locally (no pre-built images). To update:

```bash
git pull
docker compose build
docker compose up -d
```

Migrations run automatically on every start.

---

## Running Tests

AlexClaw uses Docker for testing — no local Elixir or Python installation required.

### Run all tests

```bash
make test
```

This builds and runs both Elixir and Python test suites in isolated containers.

### Run tests individually

```bash
# Elixir tests only
make test-elixir

# Python (web-automator) tests only
make test-python
```

### What happens under the hood

`make test` uses `docker-compose.test.yml` which spins up:

- **db-test** — a PostgreSQL + pgvector instance for the test database
- **test-elixir** — builds the Dockerfile `test` stage, runs migrations, then `mix test`
- **test-python** — installs pytest in the web-automator container and runs the test suite

Each run starts fresh containers — no state leaks between runs.

### Running a specific test file

```bash
docker compose -f docker-compose.test.yml build --quiet test-elixir && docker compose -f docker-compose.test.yml run --rm test-elixir \
  sh -c "mix ecto.create && mix ecto.migrate && mix test test/alex_claw/skills/web_automation_test.exs"
```

### Windows users

`make` is not installed by default on Windows. You can either:

- **Use Docker Compose directly** (works everywhere):
  ```bash
  docker compose -f docker-compose.test.yml build --quiet test-elixir && docker compose -f docker-compose.test.yml run --rm test-elixir
  docker compose -f docker-compose.test.yml build --quiet test-python && docker compose -f docker-compose.test.yml run --rm test-python
  ```
- **Install Make** via [Git for Windows](https://gitforwindows.org/) (includes Git Bash with make), [Chocolatey](https://chocolatey.org/) (`choco install make`), or WSL

---

## Platform Notes

AlexClaw runs on **Windows**, **macOS**, and **Linux** via Docker. A few things to keep in mind:

### All platforms

- **Docker Desktop memory:** The default 2 GB allocation may be tight during builds (Elixir compilation is memory-hungry). If builds fail with out-of-memory errors, increase to 4 GB in Docker Desktop > Settings > Resources
- **`.env` line endings:** If you create or edit `.env` with a Windows text editor (e.g., Notepad), values may get invisible `\r` characters appended. This causes silent authentication failures (e.g., `DATABASE_PASSWORD=changeme\r`). Use a code editor (VS Code, Notepad++) that saves with LF line endings, or run `sed -i 's/\r$//' .env` to fix

### Windows

- **Docker Desktop** is required — install from [docker.com](https://www.docker.com/products/docker-desktop/)
- **Line endings:** The `.gitattributes` file ensures shell scripts use LF line endings. The Dockerfiles also strip CRLF at build time. If you see `\r: not found` errors, run `git checkout -- entrypoint.sh` to re-checkout with correct line endings
- **Port 5001:** No known conflicts on Windows

### macOS

- **Docker Desktop** is required
- **Port 5001:** Used by AirPlay Receiver by default. Either disable it (System Settings > General > AirDrop & Handoff) or set `ADMIN_PORT=5002` in your `.env`

### Linux

- **Docker Engine** and **Docker Compose v2** (the `docker compose` plugin, not the standalone `docker-compose`)
- **`host.docker.internal`:** Does not resolve by default on Linux. The `docker-compose.yml` already includes `extra_hosts: host.docker.internal:host-gateway` for the main service. If you add custom services that need host access, add the same directive
- **File permissions:** Docker runs containers as root by default. Volume-mounted files will be owned by root on the host. This doesn't affect normal operation but may matter if you mount config or data directories

---

## Troubleshooting

### Bot not responding

- Check that `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` are correct in `.env`
- Check logs: `docker compose logs alexclaw-prod | grep -i telegram`
- Make sure you started a conversation with the bot first (send it any message)

### Database connection errors

- Ensure `DATABASE_PASSWORD` in `.env` is not empty
- Check DB health: `docker compose ps` — the `db-prod` service should show `healthy`
- Check logs: `docker compose logs db-prod`

### LLM errors

- Verify your API key is valid and has quota remaining
- Check provider status in Admin > LLM
- Check the Logs page in the admin UI — filter by `critical` or `high` severity
- If all providers fail, AlexClaw will log `No available model` — add at least one working provider

### Port conflict

If port 5001 is already in use (common on macOS — see [Step 4](#4-log-in)), set `ADMIN_PORT` in `.env`:
```
ADMIN_PORT=5002
```

### Container won't start

```bash
docker compose logs alexclaw-prod
```

Look for Elixir/Erlang crash messages. Common causes:
- Missing required env vars (`SECRET_KEY_BASE`, `DATABASE_PASSWORD`)
- Database not ready (usually resolves on retry — the healthcheck handles this)

### Bot not receiving messages (multiple instances)

If you run two AlexClaw instances with the same `TELEGRAM_BOT_TOKEN` (e.g., dev and prod), Telegram sends each update to only one of them at random. This causes silent message loss with no errors in logs. Use a separate bot token for each instance.

### Locked out after changing SECRET_KEY_BASE

Changing `SECRET_KEY_BASE` invalidates all existing sessions and makes all encrypted config values (API keys, tokens) unreadable. Log in again with your `ADMIN_PASSWORD` and re-enter any API keys via Admin > Config (or set them in `.env` and restart). If you also changed the admin password and forgot it, you'll need to set a new one in `.env` and restart.

### Web automator noVNC behind HTTPS

If you run AlexClaw behind an HTTPS reverse proxy, the noVNC recording link defaults to `http://`. Set `NOVNC_SCHEME=https` in your web-automator environment (and ensure your reverse proxy also terminates TLS for the noVNC port) to avoid mixed-content browser warnings.

### Rebuilding from scratch

```bash
docker compose down -v   # WARNING: deletes all data
docker compose up -d --build
```

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
DATABASE_OWNER_USERNAME=alexclaw
DATABASE_OWNER_PASSWORD=changeme_owner
DATABASE_USERNAME=alexclaw_app
DATABASE_PASSWORD=changeme_app
SECRET_KEY_BASE=generate_with_openssl_rand_base64_48
ADMIN_PASSWORD=changeme
CLUSTER_COOKIE=generate_with_openssl_rand_base64_32

# === Telegram ===
TELEGRAM_CHAT_ID=              # optional — auto-detected on first message

# === LLM Providers (at least one required) ===
# API keys are entered on the Config page after the first start (step 4).

# === Local Models (optional) ===
# OLLAMA_ENABLED=true
# OLLAMA_HOST=http://host.docker.internal:11434
# OLLAMA_MODEL=llama3.2

# LMSTUDIO_ENABLED=true
# LMSTUDIO_HOST=http://host.docker.internal:1234
# LMSTUDIO_MODEL=qwen2.5-14b-instruct

# === Google OAuth (optional — for Calendar, Keep skills) ===
# GOOGLE_OAUTH_CLIENT_ID=

# === Clustering (optional — multi-node) ===
# NODE_NAME=alexclaw@node1.local

# === Advanced ===
# ADMIN_PORT=5001
```

### 2. Generate secrets

Run these commands **in your terminal** and paste each output into `.env`:

```bash
# Generate DATABASE_OWNER_PASSWORD — copy the output into .env
openssl rand -hex 32

# Generate DATABASE_PASSWORD — a second, different value
openssl rand -hex 32

# Generate SECRET_KEY_BASE — copy the output into .env
openssl rand -base64 48

# Generate CLUSTER_COOKIE — copy the output into .env
openssl rand -base64 32
```

Then fill in the remaining values:

| Variable | What to do |
|---|---|
| `DATABASE_OWNER_PASSWORD` | Paste the output of the first `openssl` command. The database owner runs migrations only, in the one-shot `migrate` service |
| `DATABASE_PASSWORD` | Paste the output of the second `openssl` command. This is the application role, which AlexClaw connects as |
| `SECRET_KEY_BASE` | Paste the output of the `openssl rand -base64 48` command |
| `ADMIN_PASSWORD` | Choose a strong password for the web admin UI |
| `CLUSTER_COOKIE` | Paste the output of the `openssl rand -base64 32` command. The container does not start without it, and every node of a cluster shares the same value |
| `DATABASE_OWNER_USERNAME`, `DATABASE_USERNAME` | Leave as `alexclaw` and `alexclaw_app`. They must be two different roles: AlexClaw refuses to start as the owner. The application role is created automatically on a fresh install; to upgrade an existing one, see [Upgrading to 0.3.34](docs/deployment/upgrade-0.3.34.md) |
| `TELEGRAM_CHAT_ID` | **Optional** — leave empty and AlexClaw will auto-detect it when you send the bot its first message. Or set it manually (see [Getting Your Chat ID](#getting-your-telegram-chat-id) below) |

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

On the Config page, enter the Telegram bot token (`telegram.bot_token`) and at least one LLM API key: `llm.gemini_api_key` (a free key from [ai.google.dev](https://ai.google.dev/) gives the `light` and `medium` tiers with no credit card) or `llm.anthropic_api_key`. They are kept in OpenBao; the page shows when each was set, never the value.

> **macOS users:** Port 5001 is used by AirPlay Receiver by default. If you get a port conflict, either disable AirPlay Receiver (System Settings > General > AirDrop & Handoff) or set `ADMIN_PORT=5002` in your `.env` and restart.

### 5. Verify Telegram

Send `/ping` to your Telegram bot. You should get `pong` back.

If you left `TELEGRAM_CHAT_ID` empty, this first message also triggers auto-detection — AlexClaw saves your chat ID automatically. No further setup needed.

If the bot doesn't respond, see [Troubleshooting > Bot not responding](#bot-not-responding).

Send `/help` to see all available commands.

---

## Container Networks

`docker-compose.yml` gives its two networks fixed subnets:

| Network | Subnet | Who is on it |
|---|---|---|
| `default` | `10.213.61.0/24` | the database, `migrate` (`10.213.61.11`), AlexClaw (`10.213.61.10`) |
| `automation` | `10.213.62.0/24` | AlexClaw and the web-automator sidecar |

The database accepts network connections only from AlexClaw's and `migrate`'s
pinned addresses, listed in `db-init/pg_hba.conf`; anything else is refused before
a password is asked for. Manual backups and restores therefore run inside the
database container, over its own socket — `docker compose exec db-prod pg_dump …`,
`docker compose exec db-prod psql …` — as every command in these guides does.

If either subnet collides with a network you already use (a LAN, a VPN, another
Docker network), change it in `docker-compose.yml`, and change with it the pinned
`ipv4_address` of `alexclaw-prod` and `migrate` and the two `host` lines of
`db-init/pg_hba.conf`. They must match, or AlexClaw cannot reach its database.
Changing a subnet needs `docker compose down` before `docker compose up -d`:
Docker does not change an existing network in place. `down` without `-v` keeps
the data.

---

## Getting Your Telegram Bot Token

1. Open Telegram and search for [@BotFather](https://t.me/BotFather)
2. Send `/newbot`
3. Choose a name and username for your bot
4. BotFather will give you a token like `123456789:ABCdefGHIjklMNOpqrsTUVwxyz`
5. After the first start, enter it on the Config page (Telegram → `telegram.bot_token`), which keeps it in OpenBao. It is not set in `.env`

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
| Gemini Flash | light | Free (250 req/day) | Set `llm.gemini_api_key` on the Config page |
| Gemini Pro | medium | Free (50 req/day) | Set `llm.gemini_api_key` on the Config page |
| Claude Haiku | light | Paid | Set `llm.anthropic_api_key` on the Config page |
| Claude Sonnet | medium | Paid | Set `llm.anthropic_api_key` on the Config page |
| Claude Opus | heavy | Paid | Set `llm.anthropic_api_key` on the Config page |
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

Ollama uses the `/api/chat` endpoint (messages format). After boot, per-provider inference options (e.g., `num_ctx`, `temperature`) can be configured from **Admin > LLM Providers** — stored in an `options` JSON column on each provider.

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

Set the client ID in `.env` (`GOOGLE_OAUTH_CLIENT_ID=your-client-id`) or in
Admin > Config under the `google` category. Enter the client secret
(`google.oauth.client_secret`) and the refresh token
(`google.oauth.refresh_token`) on the Config page: both are secrets, kept in
OpenBao, and are not read from `.env`.

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

### Setup

1. In the admin UI, open **Services → Two-factor authentication** and choose *Set up*
2. Scan the QR code with your authenticator app (Google Authenticator, Authy, etc.), or type the key shown
3. Confirm with a 6-digit code from your authenticator
4. Generate your recovery codes on the same page, and store them offline

Once confirmed, workflows marked with "Require 2FA" will prompt for a code before execution.

---

## Web Automator Sidecar (Optional)

The web-automator is an optional Python/Playwright sidecar for browser automation — filling forms, clicking buttons, downloading files from sites that have no API.

### Enable

Add to your `.env`:

```bash
WEB_AUTOMATOR_ENABLED=true
WEB_AUTOMATOR_HOST=http://web-automator:6900
WEB_AUTOMATOR_TOKEN=<output of: openssl rand -hex 32>
```

`WEB_AUTOMATOR_TOKEN` is passed to both AlexClaw and the sidecar. The sidecar
answers every route except `/health` only with `Authorization: Bearer <token>`;
without a configured token it refuses them all, and AlexClaw sends it nothing.

The sidecar sits on its own `automation` network, shared with AlexClaw and not
with the database. During a replay, its browser reaches the internet only
through a filtering proxy that refuses loopback, private, link-local and other
internal addresses, including hosts on the local network and Tailscale
addresses (`100.64.0.0/10`). A recording session's browser is not filtered.

It is not built or started by a plain `docker compose up -d`. Start it with its profile:

```bash
docker compose --profile web-automation up -d
```

To include it every time, set `COMPOSE_PROFILES=web-automation` in `.env`.

### Verify

```bash
docker compose --profile web-automation ps web-automator
# STATUS shows (healthy) once its health check passes
```

The noVNC web UI for recording sessions is available at `http://localhost:6080`.
It is published on loopback only, because it gives unauthenticated control of
the automation browser. To reach it on a remote host, tunnel rather than
republish the port:

```bash
ssh -L 6080:127.0.0.1:6080 <host>
```

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

AlexClaw saves the captured actions as an automation resource — a recipe like:

```json
{
  "url": "https://httpbin.org/forms/post",
  "steps": [
    {"action": "fill", "selector": "input[name=\"custname\"]", "value": "John"},
    {"action": "fill", "selector": "input[name=\"custemail\"]", "value": "john@example.com"},
    {"action": "select", "selector": "input[name=\"size\"][value=\"medium\"]", "value": "medium"},
    {"action": "check", "selector": "input[name=\"topping\"][value=\"cheese\"]", "checked": true},
    {"action": "click", "selector": "button"}
  ]
}
```

The recorder captures fills, selects (dropdowns and radio buttons), checkboxes (with their state) and clicks, with CSS selectors. A recording is saved only if it is a valid recipe; otherwise the reply says why.

**2. Replay instantly:**

Send `/replay <resource_id>` to replay the automation headlessly and get the result.

**3. Build a workflow for scheduled replay:**

In Admin > Workflows, create a new workflow with two steps: `web_automation` (step 1), then `telegram_notify` with `{}` (step 2). Give step 1 this config, which appends two steps after the recorded ones — wait two seconds, then scrape the result text:

```json
{
  "extra_steps": [
    {"action": "wait", "seconds": 2},
    {"action": "scrape_text"}
  ]
}
```

Then assign your automation resource to the workflow under Resources, and run it with `/run <workflow_id>` or a cron schedule.

A whole play is bounded by the step's `timeout_ms` — 120 seconds when it is not set, at most 600000 — and ends as a timeout past it. `/replay` and `/automate` use the 120-second default. One play runs at a time: a second one started meanwhile is refused as busy.

### Supported Actions

A recipe is `{"url": "https://…", "steps": [...]}`. Each step has an `action` and only that action's fields, plus an optional `timeout_ms` (1–120000): how long that step may wait for its element or download; any other field, an unknown action, or a URL that is not http(s) makes the whole recipe invalid, and it is refused before anything runs.

| Action | Does | Fields |
|---|---|---|
| `navigate` | Go to a URL | `url` (http or https) |
| `click` | Click a button or link | `selector` |
| `fill` | Type into a field | `selector`, `value` (a string; may be empty), optional `input_type: "date"` |
| `select` | Pick a dropdown option, or click a radio button | `selector`, `value` |
| `check` | Set a checkbox or radio button to a state | `selector`, `checked` (`true` or `false`) |
| `wait` | Pause | `seconds` (more than 0, at most 60) |
| `keyboard` | Press a key | `key` (e.g. `"Enter"`) |
| `download` | Click and wait for the file | `selector` |
| `scrape` | Extract HTML tables | optional `selector` (default: every table) |
| `scrape_text` | Grab the visible text | optional `selector` (default: the whole page) |
| `extract_grid` | Extract a jqxGrid widget's data | `selector` |
| `screenshot` | Take a screenshot | optional `name` (`a-z`, `0-9`, `_`, `-`; up to 40), optional `full_page` |

A `fill`, `select`, `check` or `click` whose selector matches nothing ends the play with an error naming it. Recipes can be recorded with `/record` or written by hand in the resource's metadata.

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
| `docker-compose.yml` | **Single node** (default). One AlexClaw instance + DB; the web-automator is opt-in (`--profile web-automation`) |
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

- Check that the bot token is set on the Config page (it shows when it was set, never the value) and that `TELEGRAM_CHAT_ID` is correct in `.env`
- Check logs: `docker compose logs alexclaw-prod | grep -i telegram`
- Make sure you started a conversation with the bot first (send it any message)

### The admin UI is unreachable from another device

The admin UI is published on `127.0.0.1` only, so it answers on the Docker host
and nowhere else. Session cookies and MCP bearer tokens travel in clear over
HTTP, which is why reaching it across a network is not the default.

The supported way to reach it from elsewhere is a reverse proxy terminating
TLS in front of it — see [Reverse Proxy & TLS](docs/deployment/reverse-proxy.md).
Its nginx example proxies to `127.0.0.1:5001`, which is exactly what this bind
leaves in place.

To publish it elsewhere, set this in `.env` and recreate the container —
either every interface, or one machine's IP to publish on that one only:

```bash
ADMIN_BIND=0.0.0.0
ADMIN_BIND=192.168.1.10
```

### The page loads but nothing on it responds

Buttons do nothing, forms do not submit, and the page is otherwise drawn
correctly. That is the LiveView socket being rejected: the page arrives over
plain HTTP and then never connects, so nothing interactive works.

The cause is the origin. The browser sends the address it was given, and the
endpoint only accepts origins it has been told about. Behind a reverse proxy
that means the public address, which the container never sees.

The log says so, once, and nowhere else:

```
Could not check origin for Phoenix.Socket transport.
Origin of the request: http://example.com
```

Set the public origin in `.env` and recreate the container:

```bash
PHX_HOST=alexclaw.example.com
```

`CHECK_ORIGIN` takes a comma-separated list and replaces the default outright,
for anything that does not fit — several hostnames, or a proxy on plain HTTP:

```bash
CHECK_ORIGIN=https://alexclaw.example.com,http://192.168.1.10:5001
```

Unset, both `http://localhost:<port>` and `http://127.0.0.1:<port>` are accepted, where `<port>` is `ADMIN_PORT` (5001 by default).

### Skill uploads or generated skills fail to save

The container runs as uid 1000 with a read-only root filesystem. Only the
skills directory, the backup directory and `/tmp` are writable.

A volume created before this was the case is owned by root, and the app cannot
write to it. The symptom is a permission error on the skills directory while
everything else works. Correct the ownership once, with the stack stopped:

```bash
docker run --rm -v alexclaw_skills_data:/s alpine chown -R 1000:1000 /s
```

On a Linux host the backup directory is a bind mount and its ownership is the
host's, so it needs the same treatment:

```bash
chown -R 1000:1000 ./backups
```

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

The admin UI is then at `http://127.0.0.1:5002`, and the LiveView socket accepts that origin.

### Container won't start

```bash
docker compose logs alexclaw-prod
```

Look for Elixir/Erlang crash messages. Common causes:
- Missing required env vars (`SECRET_KEY_BASE`, `DATABASE_PASSWORD`)
- Database not ready (usually resolves on retry — the healthcheck handles this)

### Bot not receiving messages (multiple instances)

If you run two AlexClaw instances with the same Telegram bot token (e.g., dev and prod), Telegram sends each update to only one of them at random. This causes silent message loss with no errors in logs. Use a separate bot token for each instance.

### Locked out after changing SECRET_KEY_BASE

Changing `SECRET_KEY_BASE` invalidates all existing sessions and makes every encrypted value (API keys, tokens, the TOTP secret) unreadable. To change it deliberately, follow [Rotating SECRET_KEY_BASE](docs/deployment/rotate-secret-key-base.md).

If it was changed without a rotation, the application does not start: the log says `These stored values do not decrypt under this SECRET_KEY_BASE` and names each one, never its value. Put the old value back and restart. If the old value is lost for good, those values cannot be recovered. Follow [Lost key](docs/deployment/rotate-secret-key-base.md#lost-key) to discard exactly them, then enter them again. If you also changed the admin password and forgot it, you'll need to set a new one in `.env` and restart.

### Web automator noVNC behind a proxy

noVNC is reached through an SSH tunnel and is not meant to sit behind a public proxy.

### Rebuilding from scratch

```bash
docker compose down -v   # WARNING: deletes all data
docker compose up -d --build
```

# First Run

After completing [Installation](installation.md) — including OpenBao's initialisation — and starting the stack, here's what to expect.

## What Happens on First Boot

1. **Database migrations** — the one-shot `migrate` job creates all tables (settings, workflows, resources, knowledge, memory, etc.)
2. **Config seeding** — environment variables are written to the `settings` table. Secret settings (bot tokens, API keys) are never seeded: they are entered on the Config page and kept in OpenBao
3. **Default LLM providers** — Gemini, Claude, Ollama, and LM Studio providers are created (disabled if no API key set)
4. **Default workflows** — example workflows are seeded (Tech News Digest, Web Research, etc.)
5. **Default RSS feeds** — a set of news and tech feeds are created as resources
6. **Self-awareness indexing** — architecture docs are chunked and stored in the knowledge base

## Access the Admin UI

Open [http://localhost:5001](http://localhost:5001) in your browser and log in with the `ADMIN_PASSWORD` you set in `.env`. The first login stores the password's hash; from then on the variable is ignored.

Until a second factor exists the admin UI is read-only. Set 2FA up under
**Services → Two-factor authentication**, store the recovery codes, then
unlock editing with a code and set, on the Config page, the Telegram bot
token, `telegram.chat_id`, `telegram.owner_user_id` and an LLM API key. On the
LLM page, enable the providers that use that key.

The dashboard shows:

- Active workflows and recent runs
- LLM provider status and usage
- Skill registry (core + dynamic)
- System health

## Test Telegram

Send `/ping` to your bot — the answer is `pong` once the bot token, `telegram.chat_id` and `telegram.owner_user_id` are set. Messages from any other chat or user are ignored.

Try a few more commands:

```
/status          → System stats (uptime, memory, skills)
/skills          → List all registered skills
/workflows       → List workflows with status
/help            → Full command reference
```

## Run Your First Workflow

1. Go to **Admin > Workflows**
2. Find "Tech News Digest" and click **Run Now**
3. Watch the execution progress in real-time
4. The result is delivered to your Telegram chat

Or trigger it from Telegram:

```
/run Tech News Digest
```

## Try a Search

```
/search what is the BEAM virtual machine?
```

This invokes the `web_search` skill — searches DuckDuckGo, fetches top results, and synthesizes an answer via your configured LLM.

## Configure MCP (Optional)

To connect an MCP client:

1. Go to **Admin > Config**, unlock editing, and open the **MCP** group
2. Click **Generate** and copy the key: it is shown once
3. Configure your client — see [MCP Client Setup](../mcp/client-setup.md)

An MCP client reads AlexClaw's data and runs enabled workflows that do not require 2FA; it changes nothing.

## Next Steps

- [Configuration](configuration.md) — fine-tune settings via the Admin UI
- [Built-in Skills](../skills/builtin.md) — explore all available skills
- [Writing Custom Skills](../skills/writing-skills.md) — create your own
- [MCP Server](../mcp/overview.md) — connect MCP clients
- [OpenBao](../architecture/openbao.md#backing-up-and-restoring-openbao) — back up OpenBao beside the database

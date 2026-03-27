# First Run

After completing [Installation](installation.md) and starting the stack, here's what to expect.

## What Happens on First Boot

1. **Database migrations** — creates all tables (settings, workflows, resources, knowledge, memory, etc.)
2. **Config seeding** — environment variables are written to the `settings` table
3. **Default LLM providers** — Gemini, Claude, Ollama, and LM Studio providers are created (disabled if no API key set)
4. **Default workflows** — example workflows are seeded (Tech News Digest, Web Research, etc.)
5. **Default RSS feeds** — a set of news and tech feeds are created as resources
6. **Self-awareness indexing** — architecture docs are chunked and stored in the knowledge base

## Access the Admin UI

Open [http://localhost:5001](http://localhost:5001) in your browser and log in with the `ADMIN_PASSWORD` you set in `.env`.

The dashboard shows:

- Active workflows and recent runs
- LLM provider status and usage
- Skill registry (core + dynamic)
- System health

## Test Telegram

Send `/ping` to your bot — you should receive `pong` back.

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

If you want to connect AI clients (Claude Code, Cursor):

1. Go to **Admin > Config**
2. Set `mcp.api_key` to a strong random value (category: `mcp`, sensitive: `true`)
3. Configure your client — see [MCP Client Setup](../mcp/client-setup.md)

## Next Steps

- [Configuration](configuration.md) — fine-tune settings via the Admin UI
- [Built-in Skills](../skills/builtin.md) — explore all available skills
- [Writing Custom Skills](../skills/writing-skills.md) — create your own
- [MCP Server](../mcp/overview.md) — connect AI clients

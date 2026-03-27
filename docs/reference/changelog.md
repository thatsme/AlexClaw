# Changelog

## v0.3.13 — MCP Server (2026-03-27)

**New: Model Context Protocol integration**

- MCP server exposing all skills and workflows as tools via Streamable HTTP transport
- 6 resource URI templates for browsing knowledge, memory, workflows, runs, config, and resources
- Bearer token authentication with constant-time comparison
- `mcp_restriction` policy rule type for fine-grained tool blocking
- PolicyEngine extended with `:mcp` caller type
- AuthContext extended with `tool_name` field and `build_mcp/2`
- `/health` and `/metrics` endpoints report MCP status
- Architecture, security, and README documentation updated
- Full test coverage for MCP modules (855 tests, 0 failures)

## v0.3.12 — Execution Outcome Annotation

- `skill_outcomes` table for tracking execution quality
- `/rate` gateway command for thumbs up/down rating
- SkillAPI integration for episodic memory queries
- Per-step outcome recording with timing and output snapshots

## v0.3.11 — Workflow Registry & Live Run Control

- Real-time workflow tracking via GenServer + ETS
- Cancel running workflows from Admin UI or gateway commands
- PubSub events for step-by-step progress in the UI
- Automatic crash cleanup for orphaned runs

## v0.3.10 — Coding Conventions Enforcement

- Giulia analysis report integration
- 195 convention violations fixed
- `enforce_keys` on all structs

## v0.3.9 — Discord Gateway

- Full bidirectional Discord support via Nostrum
- Gateway behaviour pattern for multi-transport messaging
- Simultaneous Telegram + Discord operation
- Per-step `channel_id` for Discord notifications

## Earlier Versions

See [git history](https://github.com/thatsme/AlexClaw/commits/main) for the complete changelog.

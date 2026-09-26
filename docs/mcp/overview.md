# MCP Server

AlexClaw implements a [Model Context Protocol](https://modelcontextprotocol.io/) server, allowing external AI clients to read AlexClaw's data and run its workflows through a standardized protocol. An MCP client operates AlexClaw; it cannot change it.

## What is MCP?

MCP is an open protocol that enables AI assistants to interact with external tools and data sources. AlexClaw's MCP server exposes:

- **Tools** — enabled workflows that do not require 2FA, as `workflow:<name>`. There are no skill tools
- **Resources** — knowledge base, memory, workflows, runs, config, and RSS feeds

## Supported Clients

Any MCP-compatible client can connect:

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (CLI, Desktop, VS Code, JetBrains)
- [Cursor](https://cursor.sh/)
- [Claude Desktop](https://claude.ai/download)

## Architecture

```
MCP Client ──Bearer Token──> /mcp endpoint
                                │
                          McpAuth Plug (token validation)
                                │
                          McpForward Plug (deferred init)
                                │
                          Anubis StreamableHTTP Transport
                                │
                          AlexClaw.MCP.Server
                           ├── handle_tool_call ──> PolicyEngine (mcp_restriction) ──> ControlPlane.perform(:run_workflow) ──> Executor
                           └── handle_resource_read ──> ResourceProvider ──> Context modules
```

## Key Modules

| Module | Role |
|---|---|
| `AlexClaw.MCP.Server` | Anubis server — init, tool calls, resource reads |
| `AlexClaw.MCP.ToolSchema` | Maps enabled, unprotected workflows to MCP tool definitions |
| `AlexClaw.MCP.ResourceProvider` | Routes resource URIs to context modules |
| `AlexClawWeb.Plugs.McpAuth` | Bearer token validation |
| `AlexClawWeb.Plugs.McpForward` | Runtime forwarder to Anubis StreamableHTTP Plug |

## Transport

Built on [`anubis_mcp`](https://hex.pm/packages/anubis_mcp) v1.0.0 with **Streamable HTTP** transport. The server is added to the OTP supervision tree and starts automatically with the application.

## Quick Test

Once configured (see [Client Setup](client-setup.md)), verify from the command line:

```bash
# Health check — should show mcp: running
curl -s http://localhost:5001/health | jq .mcp

# MCP initialize (raw HTTP — clients handle this automatically)
curl -s http://localhost:5001/mcp \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test"}}}'
```

# Gateway Layer

The gateway layer supports multiple messaging transports via a behaviour pattern. All gateways normalize inbound messages into a common `%Message{}` struct and route responses back to the originating transport.

## Transports

| Gateway | Transport | Module |
|---|---|---|
| Telegram | Long-polling (Bot API) | `AlexClaw.Gateway.Telegram` |
| Discord | WebSocket (Nostrum) | `AlexClaw.Gateway.Discord` |
| MCP | Streamable HTTP | `AlexClaw.MCP.Server` |

## Architecture

```
Inbound message
    │
    ▼
Gateway (Telegram/Discord) ──normalize──> %Message{gateway: :telegram}
    │
    ▼
Router ──resolve gateway──> Dispatcher
    │
    ▼
Pattern match on command ──> Skill execution
    │
    ▼
Response ──route back──> originating gateway
```

## Gateway Behaviour

`AlexClaw.Gateway.Behaviour` defines the contract:

- `send_message/2` — send text to a chat
- `send_html/2` — send HTML-formatted message
- `send_photo/3` — send an image
- `name/0` — transport identifier
- `configured?/0` — whether the transport is ready

## Router

`AlexClaw.Gateway.Router` resolves the correct gateway from `opts[:gateway]` and delegates. Falls back to the first configured gateway (Telegram preferred). Provides `broadcast/2` for system-level notifications to all active gateways.

## Dispatcher

`AlexClaw.Dispatcher` is a deterministic pattern-matching router. No LLM involved in routing — zero token cost for dispatch:

```
/ping              → pong
/status            → system stats
/skills            → list from SkillRegistry
/workflows         → list all workflows
/run <id|name>     → execute a workflow
/search <q>        → WebSearch skill
/research <q>      → Research skill
/web <url> [q]     → WebBrowse skill
/help              → command list
<free text>        → Conversational skill (LLM fallback)
```

The Dispatcher threads `gateway: msg.gateway` through all send calls, ensuring responses route back to the originating transport.

## Cluster Behavior

In single-node mode, gateways always start. In a cluster:

- Gateways only start on their assigned node (`telegram.node`, `discord.node` config)
- Setting `telegram.enabled = true` auto-assigns `telegram.node` to the current node
- Cross-node config changes propagate via PubSub over BEAM distribution

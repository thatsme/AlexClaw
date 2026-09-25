# Gateway Layer

How a message becomes an action. The gateway layer normalises several transports
into one message shape, and the dispatcher turns that into a skill call without
consulting an LLM.

## Transports

Each transport implements `AlexClaw.Gateway.Behaviour` — `send_message/2`,
`send_html/2`, `send_photo/3`, `name/0`, `configured?/0`.

| Module | Role |
|---|---|
| `Gateway.Telegram` | GenServer long-polling the Telegram Bot API |
| `Gateway.Discord` | Nostrum consumer for `MESSAGE_CREATE`, sending over Nostrum's REST API |
| `Gateway.DiscordStarter` | Supervised child that configures and starts Nostrum when Discord is enabled and this node is assigned it |
| `Gateway.Router` | Resolves the target gateway from `opts[:gateway]`, falling back to the first configured one. `broadcast/2` reaches all active transports |
| `AlexClaw.Gateway` | Thin facade delegating to the Router, so callers name one module |

Inbound traffic is normalised into `%AlexClaw.Message{}` carrying the text, the
chat, and which gateway it arrived on. The dispatcher threads `gateway:` back
through every reply, so an answer returns on the transport that asked.

Discord is configured from **Admin > Config**, not from environment variables —
see [Configuration](../getting-started/configuration.md). Which node runs which
bot is covered in [Multi-Node Clustering](clustering.md).

The MCP server is a separate entry point rather than a gateway: it exposes
skills and workflows as tools to external AI clients. See
[Integrations](integrations.md).

## Dispatcher

`AlexClaw.Dispatcher` is a deterministic pattern-matching router. Routing costs
no tokens — an LLM is involved only once a command reaches a skill that uses
one, or when free text falls through to the conversational skill.

Command families, rather than an exhaustive list — the
[Commands reference](../reference/commands.md) owns that:

| Family | Commands |
|---|---|
| Status | `/ping`, `/status`, `/help`, `/llm`, `/skills` |
| Skills | `/skill list\|load\|unload\|reload\|create` |
| Workflows | `/workflows`, `/run`, `/runs`, `/cancel`, `/rate` |
| Research and web | `/research`, `/search`, `/web` — each also accepts `--tier` and `--provider` to save a default |
| GitHub | `/github pr`, `/github commit` |
| Generation | `/coder <goal>` |
| Shell | `/shell <command>` |
| Automation | `/record`, `/replay`, `/automate` |
| Google | `/tasks`, `/task add`, `/tasklists`, `/connect google`, `/disconnect google` |
| 2FA | `/setup 2fa`, `/confirm 2fa`; `/disable 2fa` is refused (turning 2FA off is in the admin UI only) |
| Anything else | The conversational skill |

Larger families live in their own modules — `Dispatcher.SkillCommands`,
`Dispatcher.AuthCommands`, `Dispatcher.AutomationCommands` — with
`Dispatcher.CommandParser` handling the shared `--tier`/`--provider` grammar.

**Several of these commands are gated by a second factor**, and are refused
outright when it is not configured. `AlexClaw.Auth.Gate` is the single place
that decides, so the admin UI and the gateway cannot disagree. Which commands,
and what happens when 2FA is off, is stated in
[SECURITY.md](https://github.com/thatsme/AlexClaw/blob/main/SECURITY.md).

## Challenge responses

A six-digit message arriving while a challenge is pending is treated as a
response to it rather than as conversation. The challenge carries the action it
authorises, so verifying the code executes the action that raised it.

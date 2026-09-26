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

Only the owner is answered: the user `telegram.owner_user_id` in the chat
`telegram.chat_id`, and the user `discord.owner_user_id` in the channel
`discord.channel_id`, all set on the admin UI's Config page. In a group or a
channel, other members' messages are ignored; with an owner setting blank,
that gateway answers nothing. A message never makes its chat or its sender the
owner.

Discord is configured from **Admin > Config**, not from environment variables —
see [Configuration](../getting-started/configuration.md). Which node runs which
bot is covered in [Multi-Node Clustering](clustering.md).

The MCP server is a separate entry point rather than a gateway: it lets
external AI clients read data and run workflows that do not require 2FA. See
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
| Workflows | `/workflows`, `/run`, `/runs`, `/cancel`, `/rate` |
| Research and web | `/research`, `/search`, `/web` — `--tier` and `--provider` with a query apply to that call only |
| GitHub | `/github pr`, `/github commit` |
| Google | `/tasks`, `/task add`, `/tasklists` |
| Anything else | The conversational skill |

A chat operates AlexClaw; it never authors it. `/skill`, `/coder`, `/shell`,
`/record`, `/replay`, `/automate`, `/setup 2fa`, `/confirm 2fa`,
`/disable 2fa`, `/connect` and `/disconnect` only answer where that is done in
the admin UI. So does `--tier` followed by a tier and no query: default tiers
and providers are set on the Config page; `/research --tier` or
`/search --tier` alone shows the current default.

`Dispatcher.AuthCommands` answers the 2FA and connection commands and approves
a protected run with a code; `Dispatcher.CommandParser` handles the shared
`--tier`/`--provider` grammar.

Every command that runs something — a skill or a workflow — is performed
through `AlexClaw.ControlPlane.perform/3` from the gateway entry point, and
audited. **One thing in a chat takes a second factor:** `/run` of a workflow
marked `Requires 2FA`, which prompts for a code and is refused outright when
2FA is not configured. A workflow with a privileged step is refused from a
chat before any code is asked for. See
[SECURITY.md](https://github.com/thatsme/AlexClaw/blob/main/SECURITY.md#control-plane-elevation).

## Challenge responses

A six-digit message arriving while a challenge is pending is treated as a
response to it rather than as conversation. The challenge names the protected
run it was raised for, and the code approves that run and nothing else; the
control plane verifies it when the run is performed.

# Integrations

Four ways the agent reaches outside itself, or is reached. Each has a security
boundary; the boundaries are stated in
[SECURITY.md](https://github.com/thatsme/AlexClaw/blob/main/SECURITY.md) and
summarised here only as far as the flow needs.

## MCP Server

`AlexClaw.MCP.Server` exposes skills and workflows to external AI clients —
Claude Code, Cursor, Claude Desktop — over the Model Context Protocol, built on
`anubis_mcp` with a Streamable HTTP transport at `/mcp`.

| Module | Role |
|---|---|
| `MCP.Server` | Anubis callbacks: initialise, tool calls, resource reads |
| `MCP.ToolSchema` | Turns a skill or workflow into a tool definition |
| `MCP.ResourceProvider` | Routes a resource URI to the context module that owns it |

Every registered skill becomes `skill:<name>` and every workflow
`workflow:<name>`. The tool list is rebuilt over PubSub whenever a skill is
loaded or unloaded, so a client that reconnects sees the current catalogue.

Six URI templates expose the data stores for reading, each accepting `list` as
an id to browse:

| Template | Data |
|---|---|
| `alexclaw://resources/{id}` | Feeds, sites, documents, APIs |
| `alexclaw://knowledge/{id}` | Knowledge entries — `search:query` supported |
| `alexclaw://memory/{id}` | Memory entries — `search:query` supported |
| `alexclaw://workflows/{id}` | Workflow definitions with steps |
| `alexclaw://runs/{id}` | Execution history |
| `alexclaw://config/{key}` | Settings, with sensitive values redacted |

A bearer token authenticates the transport, and tool calls are evaluated by the
policy engine as an `:mcp` caller. **Several tools are denied by default**, and
a token is not a substitute for the second factor those actions require
elsewhere — see SECURITY.md, and [MCP Policies](../mcp/policies.md) for managing
the rules.

## GitHub

Two entry points, one skill.

`POST /webhooks/github` verifies an HMAC-SHA256 signature before anything else.
`AlexClawWeb.Plugs.CachingBodyReader` keeps the raw request body so the
signature is checked against the bytes GitHub actually sent, rather than against
re-serialised JSON. Push events on watched branches trigger a review.

From a chat, `/github pr owner/repo 42` or `/github commit owner/repo <sha>`.

`GitHubSecurityReview` fetches the diff and truncates it to fit a local model's
context. **It calls no model itself** — the analysis is a following
`llm_transform` step, which is what makes the prompt and the tier the workflow
author's choice rather than the skill's.

## Google

`AlexClaw.Google.OAuth` runs the authorization-code flow, started with
`/connect google` and completed at the OAuth callback route.
`AlexClaw.Google.TokenManager` is a supervised process holding the token in ETS
and refreshing it before expiry, so skills never handle the refresh themselves.

`google_calendar` and `google_tasks` read through that manager.

## Web Automation

An optional Python and Playwright sidecar (`web-automator/`) running Xvfb and
noVNC in its own container, enabled with `web_automator.enabled`.

- **Record** — opens a browser session and captures actions as reproducible steps
- **Replay** — runs recorded steps headlessly, scraping, screenshotting, downloading
- **Storage** — a recording becomes a resource of type `automation`, steps in JSONB
- **Contract** — a recipe is a URL and a list of steps from a closed set of
  actions, each with only its own fields. The sidecar validates the whole recipe
  before anything runs and refuses an invalid one; a recording is saved only if
  it is a valid recipe.
- **Lifecycle** — every play has an id and a deadline (the workflow step's
  `timeout_ms`, 120 s by default, at most 600 s) and its own browser. One play
  runs at a time (`AlexClaw.WebAutomation.PlayLock`); a second is refused as
  busy. A play past its deadline ends as `{:error, :timeout}`. A play whose
  caller disconnects is cancelled; one whose caller gives up waiting is stopped
  by its id.
- **Boundary** — every route but `/health` needs a shared bearer token. The
  sidecar sits on its own `automation` network with the app, not the database,
  runs unprivileged on a read-only root, and the replay browser reaches the
  network only through an egress filter that refuses internal destinations.
  [Security](https://github.com/thatsme/AlexClaw/blob/main/SECURITY.md#web-automator-sidecar)
  has the detail.

Commands: `/record`, `/record stop`, `/replay`, `/automate`.

The noVNC interface gives unauthenticated control of that browser and is bound
to loopback for exactly that reason; reach it through an SSH tunnel. See
[Installation](https://github.com/thatsme/AlexClaw/blob/main/INSTALLATION.md).

## Backups

`db_backup` produces a compressed PostgreSQL dump to a host-mounted path and
rotates old files. It is one of the privileged skills, and is scheduled like any
other workflow step.

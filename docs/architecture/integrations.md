# Integrations

Four ways the agent reaches outside itself, or is reached. Each has a security
boundary; the boundaries are stated in
[SECURITY.md](https://github.com/thatsme/AlexClaw/blob/main/SECURITY.md) and
summarised here only as far as the flow needs.

## MCP Server

`AlexClaw.MCP.Server` lets external AI clients read AlexClaw's data and run its
workflows over the Model Context Protocol, built on `anubis_mcp` with a
Streamable HTTP transport at `/mcp`. An MCP client operates AlexClaw; it does
not author it: no MCP call changes settings, workflows, skills or policies.

| Module | Role |
|---|---|
| `MCP.Server` | Anubis callbacks: initialise, tool calls, resource reads |
| `MCP.ToolSchema` | Turns an enabled workflow that does not require 2FA into a tool definition |
| `MCP.ResourceProvider` | Routes a resource URI to the context module that owns it |

Every enabled workflow that does not require 2FA becomes `workflow:<name>`; the
list is built when a client connects. There are no skill tools. A call runs the
workflow through the control plane as `:run_workflow` from the MCP entry point,
waits for it, and answers with the run's result; a workflow with a privileged
step is refused before it starts.

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

A bearer key authenticates the transport, and a tool call is evaluated by the
policy engine as an `:mcp` caller before it reaches the control plane;
`mcp_restriction` policies can deny workflow tools by name — see
[MCP Policies](../mcp/policies.md). The key is not a substitute for a second
factor: no MCP call can start a workflow that requires 2FA.

## GitHub

Two entry points.

`POST /webhooks/github` verifies an HMAC-SHA256 signature before anything else.
`AlexClawWeb.Plugs.CachingBodyReader` keeps the raw request body so the
signature is checked against the bytes GitHub actually sent, rather than against
re-serialised JSON. A pull request opened, synchronised or reopened, or a push
to a branch in `github.watched_branches`, starts the workflow named in
`github.review_workflow`, with the event as its input, through the control
plane from the webhook entry point. With no workflow named, nothing runs and
the audit log says so; a workflow that requires 2FA, or one with a privileged
step, is refused.

From a chat, `/github pr owner/repo 42` or `/github commit owner/repo <sha>`
runs the `github_security_review` skill, through the control plane from the
gateway entry point.

`GitHubSecurityReview` fetches the diff and truncates it to fit a local model's
context. **It calls no model itself** — the analysis is a following
`llm_transform` step, which is what makes the prompt and the tier the workflow
author's choice rather than the skill's.

## Google

`AlexClaw.Google.OAuth` runs the authorization-code flow, started from the
admin UI's Services page with the page unlocked, and completed at the OAuth
callback route by the same session. The client secret and the refresh token
are kept in OpenBao.
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

Recording and replaying are done on the admin UI's Resources page, with the
page unlocked; a chat command only answers where. The recorder keeps a fill
into a password or one-time-code field as a slot without its value; a login is
attached to that slot on the Resources page and kept in OpenBao, bound to the
recording's origin. `web_automation` is a privileged step: it runs only in a
scheduled run or one the admin UI starts with a 2FA code.

The noVNC interface gives unauthenticated control of that browser and is bound
to loopback for exactly that reason; reach it through an SSH tunnel. See
[Installation](https://github.com/thatsme/AlexClaw/blob/main/INSTALLATION.md).

## Backups

`db_backup` produces a compressed PostgreSQL dump to a host-mounted path and
rotates old files. It is one of the privileged skills, and is scheduled like any
other workflow step; a manual run from the admin UI asks for a 2FA code, and a
run from a chat, MCP, a webhook or another node is refused.

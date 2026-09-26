# Skill API Reference

`AlexClaw.Skills.SkillAPI` is the interface dynamic skills use to reach the rest
of the system. Every function takes the calling module as its first argument — a
skill passes `__MODULE__`. The permissions checked are those of the skill
actually running in the process: a call that names another module is refused
with `{:error, :permission_denied}` and recorded as a denial, and code that is
not running as a skill has no permissions at all.

A call whose permission was not declared in `permissions/0` returns
`{:error, :permission_denied}` and is written to the authorization audit log.

## LLM Operations

```elixir
# Complete a prompt (requires :llm)
{:ok, response} = SkillAPI.llm_complete(MySkill, prompt, tier: :medium)

# With a system prompt and an explicit provider
{:ok, response} = SkillAPI.llm_complete(MySkill, prompt,
  tier: :light,
  provider: "ollama",
  system: "You are a classifier."
)

# The configured identity prompt, optionally scoped to a skill (requires :llm)
{:ok, system} = SkillAPI.system_prompt(MySkill, %{skill: :my_skill})
```

## Web Operations

There is no search or page-fetch helper. Skills make HTTP requests directly and
parse what comes back.

```elixir
# Options: headers, params, json, form, body, receive_timeout, retry,
# max_retries, retry_delay, redirect, max_redirects, secret_headers
{:ok, %Req.Response{body: body}} = SkillAPI.http_get(MySkill, "https://example.com")

{:ok, response} = SkillAPI.http_post(MySkill, url, json: %{q: "search term"})

{:ok, response} = SkillAPI.http_request(MySkill, :put, url, json: payload)
```

All three require `:web_read`, and a skill using any of them must declare
`def external, do: true` — see the warning at the end of this page.

Any other option returns `{:error, :option_not_allowed}`: options such as
`adapter`, `plug` or `connect_options` could replace the transport, and the
host check lives in the transport. A URL whose host is internal (loopback,
private, link-local, CGNAT) or does not resolve returns
`{:error, :blocked_host}`, and the check is repeated on every redirect hop.

`secret_headers` is the one place a credential is attached: a map of header
name to a placeholder the step was given for one of its own secret config
keys (`{{secret:NAME}}`, standing alone). Each header is set as the request is
sent, and only if its host is the one the secret is bound to; otherwise the
call returns `{:error, {:credential_refused, message}}`. A placeholder in the
URL, in `headers` or in a body is sent as written.

XML is read with `parse_xml/2`, which needs no permission. It refuses any
document that declares a document type or an entity
(`{:error, :doctype_refused}`), so nothing is expanded or fetched, and returns
plain maps that pattern matching can walk:

```elixir
{:ok, %{name: "rss", children: [channel]}} = SkillAPI.parse_xml(MySkill, body)
# each element: %{name: "item", attributes: %{"k" => "v"}, text: "…", children: [...]}
```

## Memory Operations

```elixir
# Store an entry (requires :memory_write)
{:ok, entry} = SkillAPI.memory_store(MySkill, :fact, content,
  source: "https://example.com",
  metadata: %{category: "tech"}
)

# Semantic search (requires :memory_read)
{:ok, results} = SkillAPI.memory_search(MySkill, "BEAM concurrency", limit: 10)

# Most recent entries (requires :memory_read)
{:ok, results} = SkillAPI.memory_recent(MySkill, limit: 20, kind: :fact)

# Deduplicate before storing (requires :memory_read)
{:ok, seen?} = SkillAPI.memory_exists?(MySkill, url)
```

## Knowledge Operations

```elixir
# Store (requires :knowledge_write)
{:ok, entry} = SkillAPI.knowledge_store(MySkill, :documentation, content,
  source: "https://hexdocs.pm/elixir"
)

# Semantic search (requires :knowledge_read)
{:ok, results} = SkillAPI.knowledge_search(MySkill, "GenServer patterns", limit: 5)

# Check a source before re-ingesting (requires :knowledge_read)
{:ok, seen?} = SkillAPI.knowledge_exists?(MySkill, url)

# Delete by source prefix (requires :knowledge_write)
{:ok, count} = SkillAPI.knowledge_delete(MySkill, kind: :documentation, source_prefix: "https://old.example.com/")
```

`knowledge_delete/2` requires both a kind and a non-empty prefix, and escapes
LIKE metacharacters. It cannot be used to clear the knowledge base.

## Gateway Operations

```elixir
# Markdown (requires :gateway_send, or the older :telegram_send)
:ok = SkillAPI.send_message(MySkill, "*Done*", gateway: :telegram)

# HTML
:ok = SkillAPI.send_html(MySkill, "<b>Done</b>")
```

`send_telegram/3` and `send_telegram_html/3` are aliases kept for older skills.
The destination is the configured chat — a skill chooses what to send, not where
it goes.

## Configuration

```elixir
# Read a setting (requires :config_read)
{:ok, threshold} = SkillAPI.config_get(MySkill, "skills.rss.relevance_threshold", 0.7)
```

**Secrets are not readable through this function.** A key marked `sensitive`
returns `{:error, :sensitive}`, and so does a key the configuration cache does
not know — absence is not proof that a key is safe. Secret settings — API
tokens, bot tokens, OAuth secrets — are kept in OpenBao and cannot be reached
this way.

If a skill needs to authenticate somewhere, give it the capability rather than
the credential: a configured resource it can name, or a core skill that holds
the token itself.

## Resource Operations

```elixir
# List, with optional filters (requires :resources_read)
{:ok, resources} = SkillAPI.list_resources(MySkill, %{type: "rss_feed"})

# Fetch one by ID (requires :resources_read)
{:ok, resource} = SkillAPI.get_resource(MySkill, resource_id)
```

**Both redact credentials.** A resource row carries them in two places:
`metadata["auth"]`, which the `api_request` skill turns into an authorization
header, and any userinfo embedded in the URL. The `auth` key is dropped and the
userinfo stripped before either function returns. A skill can name a resource
and ask for a request to be made against it; it cannot read the secret out.

## Cross-Skill Invocation

```elixir
# Invoke another skill by name (requires :skill_invoke)
{:ok, output, branch} = SkillAPI.run_skill(MySkill, "web_fetch", %{input: url})
```

**Four core skills cannot be invoked this way**: `shell`, `coder`, `db_backup`
and `web_automation` return `{:error, :privileged_skill}` for every caller, and
the attempt is recorded as a denial. `shell`, `db_backup` and `web_automation`
run only as workflow steps in a run the scheduler starts, or one the admin UI
starts with a 2FA code; `coder` is reached only through the Forge page.

The capability token is attenuated on each hop: a child skill receives a subset
of the caller's permissions, never more. Chains are limited to depth 3.

## Skill Outcomes

```elixir
# Past executions (requires :memory_read)
{:ok, outcomes} = SkillAPI.skill_outcomes(MySkill, "web_fetch", limit: 20)

# Aggregates (requires :memory_read)
{:ok, stats} = SkillAPI.skill_outcome_stats(MySkill, "web_fetch")
```

## Workflow Results

A skill operates AlexClaw; it does not author it. SkillAPI has no function that
writes, reads, loads or unloads a skill file, or that creates, changes or starts
a workflow, and no permission grants one. Skills are loaded and workflows built
and started in the admin UI. A skill may read the result of a workflow run:

```elixir
# Requires :workflow_read
{:ok, run} = SkillAPI.get_workflow_result(MySkill, run_id)
```

## Computation

```elixir
# Concurrency, bounded (no permission of its own; calls inside fun are checked as the skill's)
{:ok, results} = SkillAPI.parallel_map(MySkill, urls, &fetch/1, max_concurrency: 4, timeout: 30_000)
# an element that crashes or times out becomes {:error, {:exit, reason}} in its place

# A loaded module's documentation, as Code.fetch_docs/1 returns it (no permission)
{:ok, docs} = SkillAPI.module_docs(MySkill, Enum)

# A prompt built for the chosen provider's context window (requires :llm)
{:ok, text} = SkillAPI.llm_complete_fitted(MySkill, fn budget -> build(budget) end, tier: :local)
```

`max_concurrency` defaults to 4 and is at most 8
(`{:error, :too_much_concurrency}` above it); `timeout` is per element and
defaults to 30 seconds.

## What a skill's source may call

Besides `SkillAPI` and `AlexClaw.Skills.Helpers`, a dynamic skill may call
`Enum`, `Map`, `MapSet`, `List`, `Keyword`, `Tuple`, `Stream`, `Range`,
`Access`, `String`, `Integer`, `Float`, `Regex`, `Jason`, `Base`, `URI`,
`Date`, `Time`, `DateTime`, `NaiveDateTime`, `Floki`, `:math`, Logger's level
functions, and single functions elsewhere: `System.monotonic_time`,
`Process.sleep`, `Exception.message`, `:crypto.hash`, and `Path`'s pure name
functions (`basename`, `dirname`, `extname`, `join`, `relative`,
`relative_to`, `rootname`, `split`, `type`). Functions that create atoms
(`String.to_atom`, `List.to_atom`) and `spawn`, `send` and `apply` are refused.
`SweetXml` is not available; XML is read with `parse_xml/2`. The check runs on
the syntax tree at every load and every boot; a skill that fails it does not
load, and no approval changes that. The full rule is in
[SECURITY.md](https://github.com/thatsme/AlexClaw/blob/main/SECURITY.md#dynamic-skill-loading).

## Permission Model

These are the only valid values for `permissions/0`. A skill declaring anything
else is rejected at load with `unknown_permissions`.

| Permission | Operations |
|---|---|
| `:llm` | `llm_complete`, `llm_complete_fitted`, `system_prompt` |
| `:web_read` | `http_get`, `http_post`, `http_request` |
| `:gateway_send` | `send_message`, `send_html`, `send_telegram`, `send_telegram_html` |
| `:telegram_send` | accepted in place of `:gateway_send` for older skills |
| `:memory_read` | `memory_search`, `memory_recent`, `memory_exists?`, `skill_outcomes`, `skill_outcome_stats` |
| `:memory_write` | `memory_store` |
| `:knowledge_read` | `knowledge_search`, `knowledge_exists?` |
| `:knowledge_write` | `knowledge_store`, `knowledge_delete` |
| `:config_read` | `config_get` — sensitive keys are refused |
| `:resources_read` | `list_resources`, `get_resource` — credentials are redacted |
| `:skill_invoke` | `run_skill` — excluding the four privileged core skills |
| `:workflow_read` | `get_workflow_result` |

### Permissions and unattended loading

A skill generated on the Forge page loads without a 2FA code only if it is
contained and stays inside a fixed set of permissions: `:llm`, `:web_read`,
`:memory_read`, `:knowledge_read`, `:resources_read` and `:gateway_send`.
`:config_read`, `:skill_invoke`, `:workflow_read` and the write permissions are
outside it, and `:web_read` combined with any private read (`:memory_read`,
`:knowledge_read`, `:resources_read`) is refused as a pair, because reading and
then posting is an exfiltration path.

Above that ceiling, a 2FA code approves the permissions; the approval screen
names the risky ones. A code never approves calls outside the containment
allowlist — that holds for uploaded skills too.

!!! warning "External calls"
    Dynamic skills that call `http_get`, `http_post` or `http_request` must
    declare `def external, do: true`; the registry scans the source at load
    time and rejects a skill that makes those calls without it. Calling an
    HTTP or socket library directly (`Req`, `HTTPoison`, `Finch`, `Tesla`,
    `:gen_tcp`) is outside containment, and such a skill does not load. See
    [Writing Skills](writing-skills.md#external-skills).

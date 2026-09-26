# Skill API Reference

`AlexClaw.Skills.SkillAPI` is the interface dynamic skills use to reach the rest
of the system. Every function takes the calling module as its first argument and
checks that module's declared permissions before doing anything.

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
not know — absence is not proof that a key is safe. API tokens and the TOTP
secret cannot be reached this way.

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
the attempt is recorded as a denial. They are gated by two-factor authentication
where a gateway dispatches them, and a skill-to-skill call was not passing that
gate. Call them as their own workflow step instead.

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

## Permission Model

These are the only valid values for `permissions/0`. A skill declaring anything
else is rejected at load with `unknown_permissions`.

| Permission | Operations |
|---|---|
| `:llm` | `llm_complete`, `system_prompt` |
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

A skill generated by Coder or Forge loads without a two-factor code only if it
stays inside a fixed set of permissions: `:llm`, `:web_read`, `:memory_read`,
`:knowledge_read`, `:resources_read` and `:gateway_send`. `:config_read` and
`:skill_invoke` are outside it, and `:web_read` combined with any private read
is refused as a pair, because reading and then posting is an exfiltration path.

Anything above that ceiling waits for a TOTP code. This applies to generated
code only — a hand-written skill's boundary is the code entered to load it.

!!! warning "AST detection"
    Dynamic skills that call `http_get`, `http_post`, or `http_request` (or
    directly use `Req`, `HTTPoison`, `Finch`, `Tesla`, `:gen_tcp`) must declare
    `def external, do: true`. The registry AST-scans source at load time and
    rejects skills with undeclared HTTP/socket calls. See
    [Writing Skills](writing-skills.md#external-skills).

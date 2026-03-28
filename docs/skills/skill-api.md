# Skill API Reference

`AlexClaw.Skills.SkillAPI` is the interface for dynamic skills to interact with the system. Each function requires the calling module and checks permissions before execution.

## Web Operations

```elixir
# Web search (requires :web_read)
{:ok, results} = SkillAPI.web_search(MySkill, "elixir genserver patterns")

# Fetch and parse a URL (requires :web_read)
{:ok, content} = SkillAPI.web_browse(MySkill, "https://example.com")
```

## LLM Operations

```elixir
# Call an LLM (requires :llm)
{:ok, response} = SkillAPI.llm_call(MySkill, prompt, tier: :medium)

# Call with system prompt
{:ok, response} = SkillAPI.llm_call(MySkill, prompt,
  tier: :light,
  system_prompt: "You are a classifier."
)
```

## Memory Operations

```elixir
# Store a memory entry (requires :memory_write)
{:ok, entry} = SkillAPI.store_memory(MySkill, :fact, content,
  source: "https://example.com",
  metadata: %{category: "tech"}
)

# Search memory (requires :memory_read)
results = SkillAPI.search_memory(MySkill, "BEAM concurrency", limit: 10)
```

## Knowledge Operations

```elixir
# Store knowledge (requires :knowledge_write)
{:ok, entry} = SkillAPI.store_knowledge(MySkill, :documentation, content,
  source: "https://hexdocs.pm/elixir"
)

# Search knowledge (requires :knowledge_read)
results = SkillAPI.search_knowledge(MySkill, "GenServer patterns", limit: 5)
```

## Resource Operations

```elixir
# List resources (requires :resource_read)
resources = SkillAPI.list_resources(MySkill, %{type: "rss_feed"})

# Get a specific resource (requires :resource_read)
{:ok, resource} = SkillAPI.get_resource(MySkill, resource_id)
```

## Workflow Operations

```elixir
# Get workflow result (requires :workflow_read)
{:ok, run} = SkillAPI.get_workflow_result(MySkill, run_id)

# Query skill outcomes (requires :memory_read)
outcomes = SkillAPI.skill_outcomes(MySkill, "web_search", limit: 20)
```

## Permission Model

Every SkillAPI call checks the calling module's declared permissions:

| Permission | Operations |
|---|---|
| `:web_read` | `web_search`, `web_browse`, `api_request`, `http_get`, `http_post`, `http_request` |
| `:llm` | `llm_call` |
| `:memory_read` | `search_memory`, `skill_outcomes` |
| `:memory_write` | `store_memory` |
| `:knowledge_read` | `search_knowledge` |
| `:knowledge_write` | `store_knowledge` |
| `:resource_read` | `list_resources`, `get_resource` |
| `:workflow_read` | `get_workflow_result` |
| `:skill_write` | Loading/unloading skills |
| `:skill_manage` | Skill administration |
| `:workflow_manage` | Workflow CRUD operations |

If a permission is not declared in `permissions/0`, the call is denied with an audit log entry.

!!! warning "AST detection"
    Dynamic skills that call `http_get`, `http_post`, or `http_request` (or directly use `Req`, `HTTPoison`, `Finch`, `Tesla`, `:gen_tcp`) must declare `def external, do: true`. The registry AST-scans source at load time and rejects skills with undeclared HTTP/socket calls. See [Writing Skills](writing-skills.md#external-skills).

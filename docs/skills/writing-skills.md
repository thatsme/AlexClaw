# Writing Custom Skills

Custom skills are Elixir modules implementing the `AlexClaw.Skill` behaviour. They can be loaded at runtime without rebuilding the container.

## Skill Behaviour

```elixir
defmodule AlexClaw.Skills.Dynamic.MySkill do
  @moduledoc "A custom skill that does something useful."

  @behaviour AlexClaw.Skill

  @impl true
  def run(args) do
    input = args.input
    config = args.config

    # Your logic here
    result = process(input, config)

    {:ok, result, :on_success}
  end

  @impl true
  def description, do: "Does something useful with the input"

  @impl true
  def permissions, do: [:web_read, :llm]

  @impl true
  def routes, do: [:on_success, :on_error]

  # UI metadata — controls which fields appear in the step editor
  @impl true
  def step_fields, do: [:llm_tier, :llm_model, :prompt_template, :config]

  @impl true
  def config_hint, do: ~s|{"option": "value"}|
end
```

## Required Callbacks

| Callback | Return | Description |
|---|---|---|
| `run/1` | `{:ok, result}` or `{:ok, result, :branch}` or `{:error, reason}` | Main execution |

## Optional Callbacks

### Core

| Callback | Default | Description |
|---|---|---|
| `description/0` | `"<name> skill"` | Human-readable description |
| `permissions/0` | `[]` | Required permissions (see [Authorization](../security/authorization.md)) |
| `routes/0` | `[]` | Possible outcome branches for conditional routing |
| `version/0` | `"1.0.0"` | Skill version string |
| `external/0` | `false` | Whether the skill fetches data from external sources |

### UI Metadata

These callbacks control how the workflow step editor renders when your skill is selected. If not declared, all fields are shown (backward compatible).

| Callback | Default | Description |
|---|---|---|
| `step_fields/0` | `[:llm_tier, :llm_model, :prompt_template, :config]` | Which optional fields to show in the step editor. Use `[:config]` for skills that don't use LLM. Use `[]` for skills with no configurable fields. |
| `config_hint/0` | `""` | Placeholder text shown in the config JSON textarea |
| `config_scaffold/0` | `%{}` | Default config map pre-filled when adding a new step |
| `config_presets/0` | `%{}` | Named config templates shown as buttons (e.g. `%{"GET" => %{"method" => "GET"}}`) |
| `prompt_presets/0` | `%{}` | Named prompt templates shown as buttons (e.g. `%{"Summarize" => "Summarize:\n\n{input}"}`) |
| `config_help/0` | `"Skill-specific parameters as JSON."` | Help text shown as tooltip on the config field |
| `prompt_help/0` | `"Template sent to the LLM. Use {input} for previous step output."` | Help text shown as tooltip on the prompt field |

## The `args` Map

Every skill receives a map with these keys:

| Key | Type | Description |
|---|---|---|
| `input` | any | Output from the previous workflow step (or user input) |
| `config` | map | Step-specific configuration from the workflow editor |
| `resources` | list | Resources assigned to the workflow |
| `workflow_run_id` | integer or nil | Current run ID (nil if standalone) |
| `llm_provider` | string or nil | Provider override |
| `llm_tier` | string | LLM tier for this step |
| `prompt_template` | string or nil | Handlebars template for LLM input |

## Using SkillAPI

Dynamic skills interact with the system through `AlexClaw.Skills.SkillAPI`:

```elixir
# Search the web (requires :web_read permission)
{:ok, results} = SkillAPI.web_search(__MODULE__, query)

# Call an LLM (requires :llm permission)
{:ok, response} = SkillAPI.llm_call(__MODULE__, prompt, tier: :medium)

# Store in memory (requires :memory_write permission)
{:ok, entry} = SkillAPI.store_memory(__MODULE__, :fact, content, source: url)

# Search memory (requires :memory_read permission)
results = SkillAPI.search_memory(__MODULE__, query, limit: 10)
```

## External Skills

If your skill fetches data from external sources (HTTP requests, APIs, RSS feeds), declare `external/0`:

```elixir
@impl true
def external, do: true
```

This enables automatic content sanitization when your skill's output flows through the workflow engine. The `ContentSanitizer` strips prompt injection payloads from external content before it reaches the LLM.

**AST enforcement:** At load time, the registry scans your source for calls to HTTP/socket libraries (`Req`, `HTTPoison`, `Finch`, `Tesla`, `:gen_tcp`, `SkillAPI.http_*`). If detected without `external/0`, your skill is **rejected**. This is fail-closed — no exceptions.

```elixir
# This will be REJECTED — uses Req.get but doesn't declare external/0
defmodule AlexClaw.Skills.Dynamic.BadFetcher do
  @behaviour AlexClaw.Skill
  def permissions, do: [:web_read]
  def run(args) do
    {:ok, resp} = Req.get(args[:input])
    {:ok, resp.body, :on_success}
  end
end

# This will be ACCEPTED — declares external/0
defmodule AlexClaw.Skills.Dynamic.GoodFetcher do
  @behaviour AlexClaw.Skill
  @impl true
  def external, do: true
  def permissions, do: [:web_read]
  def run(args) do
    {:ok, resp} = Req.get(args[:input])
    {:ok, resp.body, :on_success}
  end
end
```

## Namespace Requirement

Dynamic skills **must** be in the `AlexClaw.Skills.Dynamic.*` namespace:

```elixir
# Correct
defmodule AlexClaw.Skills.Dynamic.MySkill do

# Wrong — will be rejected
defmodule MySkill do
```

## Returning Results

```elixir
# Success with branch (for conditional routing)
{:ok, "processed data", :on_success}

# Success without branch (linear workflows)
{:ok, "processed data"}

# Error
{:error, "something went wrong"}
```

## Example: URL Health Checker

```elixir
defmodule AlexClaw.Skills.Dynamic.UrlHealthCheck do
  @moduledoc "Check if a list of URLs are responding."

  @behaviour AlexClaw.Skill

  @impl true
  def external, do: true

  @impl true
  def run(args) do
    urls = parse_urls(args.input)

    results =
      Enum.map(urls, fn url ->
        case Req.get(url, receive_timeout: 5_000) do
          {:ok, %{status: status}} -> %{url: url, status: status, ok: status < 400}
          {:error, reason} -> %{url: url, status: nil, ok: false, error: inspect(reason)}
        end
      end)

    down = Enum.reject(results, & &1.ok)

    if Enum.empty?(down) do
      {:ok, "All #{length(results)} URLs are healthy", :on_success}
    else
      {:ok, "#{length(down)}/#{length(results)} URLs are down:\n" <>
            Enum.map_join(down, "\n", &"  - #{&1.url}"), :on_error}
    end
  end

  @impl true
  def description, do: "Check if URLs are responding (HTTP status < 400)"

  @impl true
  def permissions, do: [:web_read]

  @impl true
  def routes, do: [:on_success, :on_error]

  # UI metadata — step editor shows only config, no LLM fields
  @impl true
  def step_fields, do: [:config]

  @impl true
  def config_hint, do: ~s|{"timeout": 5000}|

  @impl true
  def config_scaffold, do: %{"timeout" => 5000}

  @impl true
  def config_help, do: "timeout: HTTP timeout in ms per URL (default 5000). Input: newline-separated URLs."

  defp parse_urls(input) when is_binary(input), do: String.split(input, "\n", trim: true)
  defp parse_urls(input) when is_list(input), do: input
  defp parse_urls(_), do: []
end
```

## Example: Scraper (No LLM)

A skill that scrapes data and embeds it — no LLM fields needed in the step editor:

```elixir
defmodule AlexClaw.Skills.Dynamic.HexdocsScraper do
  @behaviour AlexClaw.Skill

  @impl true
  def step_fields, do: [:config]

  @impl true
  def config_hint, do: ~s|{"packages": ["phoenix", "ecto"]}|

  @impl true
  def config_scaffold, do: %{"packages" => []}

  @impl true
  def config_help, do: "packages: list of Hex package names to scrape and index."

  @impl true
  def run(args) do
    # ... scraping logic
  end
end
```

The step editor will show only the Config (JSON) field — no LLM Tier, Provider, or Prompt Template.

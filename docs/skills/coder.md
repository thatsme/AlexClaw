# Coder — Autonomous Skill Generation

The `coder` skill generates dynamic skills from natural language descriptions using a local LLM. Describe what you want, and AlexClaw writes the Elixir module, validates it, and loads it into the running system.

## Usage

From Telegram or Discord:

```
/coder Create a skill that checks if a website is up and returns the response time
```

From MCP:

```
skill:coder with input "Monitor CPU temperature from /sys/class/thermal"
```

## How It Works

1. **Goal parsing** — the natural language description is sent to the local LLM with an improved system prompt containing the Skill behaviour spec, SkillAPI reference, args/JSON key examples, and the skill template fetched directly from the database
2. **Code generation** — the LLM generates a complete Elixir module in the `AlexClaw.Skills.Dynamic.*` namespace. `<think>` tags (from models like Qwen3 in thinking mode) are stripped from the response before code extraction
3. **Validation** — the generated code is syntax-checked and compiled in a sandbox
4. **Loading** — if valid, the skill is loaded into the SkillRegistry and becomes immediately available

## Output Branches

| Branch | Description |
|---|---|
| `on_created` | Skill was successfully generated and loaded |
| `on_workflow_created` | A workflow was also created using the new skill |
| `on_error` | Generation or validation failed |

## Limitations

- Uses the `local` LLM tier — requires a local model (Ollama or LM Studio) with good code generation capabilities
- Generated skills may need manual review and refinement
- Complex skills with external dependencies may not work out of the box
- The generated skill still needs proper permissions declared

## Workflow Integration

The coder can be used as a workflow step. Combined with other skills, it enables meta-automation — workflows that create new workflows.

!!! warning "Security consideration"
    The coder skill generates and loads executable code. In production, review generated skills before relying on them. The standard dynamic skill security layers (namespace enforcement, permission sandbox, integrity verification) still apply.

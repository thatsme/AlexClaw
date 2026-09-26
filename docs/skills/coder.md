# Forge — Skill Generation

The Forge page generates a dynamic skill from a natural-language goal: it writes the Elixir module, checks it, and loads it when the checks allow. The generation engine is the `coder` core skill, which is reached only through the Forge page.

## Usage

Open **Admin > Forge** with the page unlocked (a 2FA elevation), describe the goal, choose the provider, and start. Generation is an authoring action: it is not available from a chat, from MCP, or as a workflow step (`coder` saved as a step is reported as unavailable).

## How It Works

1. **Prompt** — the goal is sent with the Skill behaviour, the SkillAPI reference and context retrieved from the knowledge base (the skill template, examples, documentation). `<think>` tags are stripped from the response before the code is extracted.
2. **Staging** — the module (namespace `AlexClaw.Skills.Dynamic.*`) is written to a pending directory, never the live one.
3. **Checks** — the syntax-tree checks and containment run on the staged source; violations are fed back to the model for another attempt.
4. **Loading** — contained code within the unattended permissions (`:llm`, `:web_read`, `:memory_read`, `:knowledge_read`, `:resources_read`, `:gateway_send`, and not `:web_read` together with a private read) loads at once. Contained code asking for more stays staged and waits for a 2FA code that approves its permissions. Code calling outside the allowlist never loads.

## Limitations

- Output quality depends on the model; a local model keeps generation on the host, a cloud provider puts a third party in the loop for code that runs in the VM
- Generated skills may need review and refinement before they are relied on
- The model writes the permissions too: review them on the approval screen

!!! warning "Security consideration"
    Generated code is compiled into the running VM. Containment, the permission ceiling and the 2FA approval are described in [SECURITY.md](https://github.com/thatsme/AlexClaw/blob/main/SECURITY.md#dynamic-skill-loading).

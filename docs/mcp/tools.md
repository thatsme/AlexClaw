# MCP Tools

Every enabled workflow that does not require 2FA is exposed as an MCP tool. There are no skill tools: a skill runs inside a workflow.

## Naming

| Type | MCP Tool Name | Example |
|---|---|---|
| Workflow | `workflow:<name>` | `workflow:Tech News Digest` |

A call to a `skill:` name returns a tool error saying skills run inside workflows.

## Discovery

The tool list is built when a client connects. Each tool has:

- **name** — `workflow:<name>`
- **description** — the workflow's description, or "Run the <name> workflow"
- **input_schema** — one optional `input` string, passed to the first step

A workflow enabled, disabled or marked `Requires 2FA` afterwards appears or disappears at the client's next connection.

## Execution Flow

When a client calls a tool:

1. **Resolve** — the workflow is found by name
2. **Policy check** — `PolicyEngine.evaluate/2` as an `:mcp` caller, where `mcp_restriction` policies apply (see [Policy Enforcement](policies.md))
3. **Run** — `ControlPlane.perform(:run_workflow, …)` from the MCP entry point: refused for a disabled or protected workflow and for one with a privileged step (`shell`, `coder`, `db_backup`, `web_automation`), audited either way
4. **Response** — MCP waits for the run to finish and answers with its id, status and result as JSON

There is no MCP-side time limit: a long run holds the call until it ends, so a proxy in front of `/mcp` needs a read timeout at least as long as the longest workflow.

## Error Responses

| Error | Cause |
|---|---|
| `-32602` (invalid params) | Unknown workflow or tool name |
| Execution error | `mcp_restriction` policy matched |
| Tool error | Run refused (protected, disabled, privileged step) or returned an error; a `skill:` name |

## Available Tools

The exact tool list depends on the enabled workflows. Use `tools/list` from the MCP client.

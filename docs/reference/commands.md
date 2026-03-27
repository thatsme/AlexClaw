# Telegram & Discord Commands

All commands work identically on both Telegram and Discord. Responses route back to the originating transport.

## General

| Command | Description |
|---|---|
| `/ping` | Connectivity check — returns `pong` |
| `/status` | System stats (uptime, memory, active skills) |
| `/help` | Full command list |

## Skills

| Command | Description |
|---|---|
| `/skills` | List all registered skills (core + dynamic) |

!!! note "Skill management"
    Loading, unloading, and reloading skills is Admin UI only (2FA enforced).

## Workflows

| Command | Description |
|---|---|
| `/workflows` | List all workflows with status and schedule |
| `/run <id\|name>` | Execute a workflow on demand (supports 2FA gating) |
| `/runs` | List active (running) workflows |
| `/cancel <run_id>` | Cancel a running workflow |
| `/rate <run_id>` | View/rate workflow step outcomes (thumbs up/down) |

## Search & Research

| Command | Description |
|---|---|
| `/search <query>` | Web search with LLM synthesis |
| `/search --tier <T>` | Save default search tier |
| `/research <query>` | Deep research with memory context |
| `/research --tier <T>` | Save default research tier |
| `/web <url> [question]` | Fetch URL and summarize or answer |
| `/web --tier <T>` | Save default web browse tier |

## GitHub

| Command | Description |
|---|---|
| `/github pr <owner/repo> [number]` | Review PR for security issues |
| `/github commit <owner/repo> <sha>` | Review commit for security issues |

## Shell

| Command | Description |
|---|---|
| `/shell <command>` | Execute whitelisted OS command (2FA-gated) |

## Code Generation

| Command | Description |
|---|---|
| `/coder <goal>` | Generate a dynamic skill from description |

## Google Services

| Command | Description |
|---|---|
| `/connect google` | Initiate Google OAuth flow |
| `/tasks` | List Google Tasks |
| `/task add <title>` | Create a new task |
| `/tasklists` | List task lists |

## Browser Automation

| Command | Description |
|---|---|
| `/record <url>` | Start browser recording |
| `/record stop <session_id>` | Stop recording, save as resource |
| `/replay <id>` | Replay a saved automation |
| `/automate <url>` | Headless scrape/screenshot |

## LLM

| Command | Description |
|---|---|
| `/llm` | Provider status and daily usage |

## 2FA

| Command | Description |
|---|---|
| `/setup 2fa` | Generate TOTP secret and QR code |
| `/confirm 2fa <code>` | Confirm 2FA setup |
| `/disable 2fa` | Disable 2FA |

## Free Text

Any message that doesn't match a command is routed to the `conversational` skill for LLM-powered conversation with memory context.

# Telegram & Discord Commands

All commands work identically on both Telegram and Discord. Responses route back to the originating transport.

Only the owner is answered: the user `telegram.owner_user_id` in `telegram.chat_id`, or `discord.owner_user_id` in `discord.channel_id`, set in the admin UI. With the owner user id blank, a gateway answers nothing. A chat operates AlexClaw — runs, reads, conversation — and never changes it.

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
    Skills are loaded, reloaded and unloaded on the admin UI's Skills page only.
    `/skill` answers that.

## Workflows

| Command | Description |
|---|---|
| `/workflows` | List all workflows with status and schedule |
| `/run <id\|name>` | Run a workflow. One marked `Requires 2FA` asks for a code in the chat; one with a `shell`, `coder`, `db_backup` or `web_automation` step is refused (it runs from its schedule, or from the admin UI with a code) |
| `/runs` | List active (running) workflows |
| `/cancel <run_id>` | Cancel a running workflow |
| `/rate <run_id>` | View/rate workflow step outcomes (thumbs up/down) |

## Search & Research

| Command | Description |
|---|---|
| `/search <query>` | Web search with LLM synthesis |
| `/research <query>` | Deep research with memory context |
| `/web <url> [question]` | Fetch URL and summarize or answer |
| `/search --tier <T> <query>` (also `/research`, `/web`) | Use tier `<T>` (or `--provider <name>`) for this call only. Defaults are set on the Config page; `/search --tier` or `/research --tier` alone shows the current one |

## GitHub

| Command | Description |
|---|---|
| `/github pr <owner/repo> [number]` | Fetch a PR's diff |
| `/github commit <owner/repo> <sha>` | Fetch a commit's diff |

A review with a model is a workflow: `github_security_review` followed by `llm_transform`.

## Google Services

| Command | Description |
|---|---|
| `/tasks` | List Google Tasks |
| `/task add <title>` | Create a new task |
| `/tasklists` | List task lists |

## LLM

| Command | Description |
|---|---|
| `/llm` | Provider status and daily usage |

## Done in the admin UI

These commands only answer where the action is done: `/skill` (Skills page), `/coder` (Forge page), `/shell` (a `shell` step in a workflow), `/record`, `/replay`, `/automate` (Resources page), `/setup 2fa`, `/confirm 2fa`, `/disable 2fa`, `/connect google`, `/disconnect google` (Services page).

2FA is set up, and turned off, on the Services page of the admin UI: turning it
off takes a current authenticator code or, for a lost phone, a recovery code.
The secret never travels over a chat.

## 2FA in a chat

A six-digit reply to a pending challenge approves the protected workflow run it was raised for, and nothing else.

## Free Text

Any message that doesn't match a command is routed to the `conversational` skill for LLM-powered conversation with memory context.

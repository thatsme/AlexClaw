# Admin UI

Phoenix LiveView admin interface at `http://localhost:5001`. All routes except `/login` and `/health` require authentication.

## Pages

| Page | Route | Description |
|---|---|---|
| Dashboard | `/` | System overview, active runs, recent logs |
| Workflows | `/workflows` | Workflow list (filterable), editor, export/import, run history, step results |
| Workflow runs | `/workflows/:id/runs` | Run history and step results of one workflow |
| Scheduler | `/scheduler` | Cron schedule management, next run times |
| Skills | `/skills` | Core and dynamic skill registry, upload/reload/unload |
| Forge | `/forge` | Skill generation from a goal; loads contained code, asks for a code for more permissions |
| Config | `/config` | Runtime settings by category, secret settings shown as set or not set, yellow tooltip hints, `embedding.provider` dropdown |
| LLM Providers | `/llm` | Provider list, tier assignment, priorities, usage stats, dynamic options form (adapts per provider type — e.g., `num_ctx` for Ollama, thinking toggle for Qwen3) |
| Resources | `/resources` | RSS feeds, websites, documents, APIs |
| Memory | `/memory` | Memory store browser, search |
| Policies | `/policies` | Policy rules, audit log viewer |
| Logs | `/logs` | Real-time log viewer with severity filters |
| Chat | `/chat` | Direct conversation with LLM (web-based) |
| Services | `/services` | External service status, real connectivity checks (DB, Google, Telegram, Discord, 2FA, Ollama, LM Studio, GitHub, Web Automator), 2FA set-up and turn-off, recovery codes, the Google connection |
| Database | `/database` | Table browser, backup download, data export, restore (restore takes a 2FA code) |
| Cluster | `/cluster` | Registered nodes, status, connection |

## Key Features

- **Real-time updates** — LiveView pushes changes without page refresh
- **Server-rendered** — LiveView throughout; the chat page uses one small client hook
- **Workflow editor** — visual step editor with drag-and-drop ordering, branch routing, resilience config
- **Workflow export/import** — export workflows as self-contained JSON, import with automatic resource creation
- **Workflow filter** — search/filter workflow list by name
- **Active runs panel** — real-time step-by-step progress with cancel button
- **Config categories** — organized by domain (skills, llm, prompts, identity, etc.)
- **Unlock editing** — every change (settings, workflows, resources, providers, policies, skills, nodes) needs the page unlocked with a TOTP code: a 15-minute elevation of that session, shared by its tabs. A chat cannot unlock it.
- **Per-action codes** — loading or reloading a skill, restoring the database, and running a workflow marked `Requires 2FA` or containing a privileged step each take a code of their own, typed on the page. A protected run is also offered to the owner's chat; a run with a privileged step is not.
- **Secret fields** — show when the value was set, never the value; an empty input keeps it, a new value replaces it.

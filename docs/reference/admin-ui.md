# Admin UI

Phoenix LiveView admin interface at `http://localhost:5001`. All routes except `/login` and `/health` require authentication.

## Pages

| Page | Route | Description |
|---|---|---|
| Dashboard | `/` | System overview, active runs, recent logs |
| Workflows | `/workflows` | Workflow list (filterable), editor, export/import, run history, step results |
| Scheduler | `/scheduler` | Cron schedule management, next run times |
| Skills | `/skills` | Core and dynamic skill registry, upload/reload/unload |
| Config | `/config` | Runtime settings by category, sensitive value masking |
| LLM Providers | `/llm` | Provider list, tier assignment, priorities, usage stats |
| Resources | `/resources` | RSS feeds, websites, documents, APIs |
| Feeds | `/feeds` | RSS feed management (filtered resource view) |
| Knowledge | `/knowledge` | Knowledge base browser, search, entry counts by kind |
| Memory | `/memory` | Memory store browser, search |
| Policies | `/policies` | Policy rules, audit log viewer |
| Logs | `/logs` | Real-time log viewer with severity filters |
| Chat | `/chat` | Direct conversation with LLM (web-based) |
| Nodes | `/nodes` | Cluster node status, connectivity |

## Key Features

- **Real-time updates** — LiveView pushes changes without page refresh
- **No JavaScript hooks** — fully server-rendered
- **Workflow editor** — visual step editor with drag-and-drop ordering, branch routing, resilience config
- **Workflow export/import** — export workflows as self-contained JSON, import with automatic resource creation
- **Workflow filter** — search/filter workflow list by name
- **Active runs panel** — real-time step-by-step progress with cancel button
- **Config categories** — organized by domain (skills, llm, prompts, identity, etc.)
- **Sensitive masking** — API keys show partial values, full value only during edit
- **2FA integration** — skill management operations trigger TOTP verification via Telegram/Discord

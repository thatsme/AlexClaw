# Roadmap

Planned features and improvements, roughly ordered by priority.

---

## Next Up

### Semantic Search (Memory)

The pgvector column and search infrastructure already exist but embedding generation is stubbed out. Wiring up an actual embedding model (e.g., Gemini's `text-embedding-004`) would unlock vector-based memory recall instead of keyword fallback.

**Status:** Database schema ready, `LLM.embed/2` returns `nil`.

### Workflow Retry & Error Handling

Workflows currently fail-fast — if any step errors, the whole run stops. Planned improvements:

- Configurable retry count per step (with backoff)
- Skip-on-error option for non-critical steps
- Conditional step execution based on previous step outcome

### Google Calendar Event Creation

Calendar is currently read-only (`fetch_events`). Adding event creation would complete the integration:

- `/event add <title> <date> <time>` Telegram command
- `google_calendar` skill with `"action": "create"` config
- Requires upgrading OAuth scope to `calendar.events`

---

## Planned

### External Event Triggers

Workflows can only run on a cron schedule or manual trigger. Planned event sources:

- RSS item with relevance score above threshold
- GitHub webhook events (new issue, review requested)
- API polling with change detection

### Workflow Templates & Export

- Pre-built workflow templates for common patterns (daily briefing, PR review, content monitoring)
- Export/import workflows as JSON for sharing between instances

### Analytics Dashboard

The current dashboard shows basic stats. Planned additions:

- Workflow success/failure rates over time
- LLM cost tracking per provider and per workflow
- Execution time trends

### Email Integration

SMTP skill for sending email notifications as a workflow step. IMAP polling as a workflow trigger source.

### Multi-Gateway Support

Additional notification/command channels beyond Telegram:

- Slack (bot + incoming webhooks)
- Discord (webhook notifications)

---

## Someday

### ~~Secrets Encryption at Rest~~ ✅ Completed (v0.1.1)

Sensitive config values (API keys, tokens) are now encrypted at rest using AES-256-GCM, derived from `SECRET_KEY_BASE`. Existing plaintext values are automatically encrypted on startup.

### SECRET_KEY_BASE Rotation Tool

Changing `SECRET_KEY_BASE` renders all AES-256-GCM encrypted settings unreadable. A CLI migration tool is needed:

- Accept old and new key as arguments
- Decrypt all sensitive settings with old key, re-encrypt with new key
- Validate round-trip before committing changes
- Support dry-run mode to preview affected rows

### Visual Automation Editor

Replace raw JSON editing for web automation recipes with a visual step editor in the admin UI. Drag-and-drop step ordering, selector picker, live preview.

### Workflow Step Dependencies

Allow workflows to depend on other workflows — "run B only after A completes successfully." Enables complex multi-workflow pipelines.

### Per-Skill Rate Limiting

Global LLM rate limits exist but there's no per-skill throttling. Would prevent a single noisy workflow from exhausting daily quotas.

### Pre-built Docker Images

Currently built from source on every `docker compose up`. Publishing multi-arch images to GitHub Container Registry would cut setup time significantly.

---

## Not Planned

These are explicitly out of scope for the foreseeable future:

- **Multi-user access control** — AlexClaw is a single-user personal agent by design
- **Local file system access** — security risk; use API Request skill to interact with file-serving APIs instead
- **Mobile app** — Telegram serves as the mobile interface

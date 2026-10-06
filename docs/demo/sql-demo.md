# SQL demo

A PostgreSQL database of a fictional wholesaler, and two workflows that read
it with the `sql_query` step, summarise the result with the local model and
send it to Telegram. Every name and number in the database is generated:
nothing in it is real.

The demo database runs in its own container under the compose profile
`demo`, on an internal network with no port published. AlexClaw joins that
network only when the demo's own compose file, `docker-compose.demo.yml`, is
given on top of `docker-compose.yml`; a plain `docker compose up -d` leaves
AlexClaw on its own networks. Its data lives in memory and is generated again, identically, at
every start: customers, products, orders and invoices over two years up to
2026-09-30, in five regions, with some invoices past due. AlexClaw reads it
as the role `alexclaw_reader`, which may read the tables and nothing else.

What a connection and a `sql_query` step guarantee is described in
[SECURITY.md](https://github.com/thatsme/AlexClaw/blob/main/SECURITY.md),
"Database Connections (SQL Read)", with the known limitations: database text
reaching an LLM prompt is not sanitised, and `verify_full` uses the system's
CAs only.

## 1. Start the demo database

Choose a password for the read-only role and put it in `.env`:

```bash
DEMO_READER_PASSWORD=<a password>
```

Start the profile with the demo's compose file:

```bash
docker compose -f docker-compose.yml -f docker-compose.demo.yml --profile demo up -d
docker compose ps demo-db          # healthy after a few seconds
```

AlexClaw's container is recreated once, to attach it to the demo network.

Without `DEMO_READER_PASSWORD` the container refuses to start — it restarts,
saying `set DEMO_READER_PASSWORD in .env` in its log (`docker compose logs
demo-db`) — until the variable is set and the container recreated
(`docker compose -f docker-compose.yml -f docker-compose.demo.yml --profile demo up -d --force-recreate demo-db`).

## 2. Add the connection

On the **Connections** page (editing unlocked with a code), add:

| Field | Value |
|---|---|
| Name | `demo` |
| Host | `demo-db` |
| Port | `5432` |
| Database | `demo` |
| User | `alexclaw_reader` |
| TLS mode | `disable` (the demo network is internal; a real server wants `verify_full`) |
| Password | the value of `DEMO_READER_PASSWORD` |

The password is stored in OpenBao, bound to this connection. **Test** should
answer "connected", and the Services page shows the connection as up.

## 3. Import the workflows

On the **Workflows** page, import the two files from `docs/demo/workflows/`:

- `weekly-sales-brief.json` — last week's sales by region and product
  category → a short brief → Telegram;
- `overdue-invoices.json` — unpaid invoices past their due date, ordered by
  amount times days overdue → a prioritised follow-up list → Telegram.

Each `sql_query` step is checked against the database when it is saved — an
import saves it — so the connection must exist and be up first. The
workflows use the `local` model tier and the Telegram bot configured on the
Config page.

## 4. Run them

Run each workflow from the Workflows page. The run history shows each step's
output: the query's `columns`, `rows` and `row_count`, then the model's text,
then the delivery.

Both queries are relative to the data's latest order date, so they return
the same rows whenever the demo runs. A schedule can be set on each workflow
like any other.

## Stopping

```bash
docker compose --profile demo stop demo-db
docker compose --profile demo rm -f demo-db
docker compose up -d               # AlexClaw back on its own networks only
```

The data goes with the container. The connection and the workflows stay
until they are deleted (the connection can be deleted once no step uses it).

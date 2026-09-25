# Multi-Node Clustering

AlexClaw supports multi-node BEAM clustering. Each node runs its own executor independently; nodes exchange workflow outputs via dedicated skills.

## How It Works

Nodes connect via Erlang distribution using EPMD (Erlang Port Mapper Daemon). Each node must share the same `CLUSTER_COOKIE`.

```
Node A (alexclaw@node1.local)        Node B (alexclaw@node2.local)
  ├── Executor                         ├── Executor
  ├── SkillRegistry                    ├── SkillRegistry
  ├── Telegram Gateway                 ├── Discord Gateway
  └── send_to_workflow ──call─────────> receive_from_workflow
```

## Cluster Manager

`AlexClaw.Cluster.Manager` is a GenServer that:

- Registers its own node at boot; another node is registered only in the admin UI (Cluster page). A node that connects without being registered is not registered by connecting — it needs only the cookie — and its arrival is written to the audit log
- Pings known nodes from the DB 5 seconds after boot
- Updates a registered node's status on `:nodeup`/`:nodedown` events
- Handles incoming remote workflow triggers

## Cross-Node Workflow Flow

1. Node A runs a workflow with a `send_to_workflow` step
2. `send_to_workflow` calls Node B's `AlexClaw.Cluster.Manager` directly (a `GenServer.call` to `{Manager, node_b}`, 5s timeout). Node B takes the sender from the connection — the node of the calling process — never from a name the request carries
3. Node B refuses the request, with an audit row and before any run starts, unless the sender is a registered node, step 1 of the enabled target workflow is `receive_from_workflow`, that step's `allowed_nodes` names the sender, and the workflow does not require 2FA
4. The target workflow is spawned via `Task.Supervisor`
5. `receive_from_workflow` receives the data as input with `_source_node` in config, and checks `allowed_nodes` again

`allowed_nodes` must name every node that may trigger the workflow. An empty or absent list allows no one.

## Node Assignment

Workflows have an optional `node` field:

- **Set** — only that node's scheduler picks it up
- **Null** — cluster-wide, any node can run it

The Admin UI shows a "Run on" dropdown populated from connected cluster nodes.

## Configuration

| Variable | Description |
|---|---|
| `NODE_NAME` | Node name (default: `alexclaw@node1.local`) |
| `CLUSTER_COOKIE` | Shared authentication cookie |

!!! danger "Cookie security"
    Generate `CLUSTER_COOKIE` with `openssl rand -base64 32`. Treat it like `SECRET_KEY_BASE`. EPMD port (4369) and BEAM distribution ports should NOT be exposed to the internet.

## Docker Swarm Setup

A `docker-compose_swarm.yml` is included for local multi-node testing. Each node gets its own service entry with a unique `NODE_NAME`.

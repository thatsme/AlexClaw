# Multi-Node Clustering

AlexClaw supports multi-node BEAM clustering. Each node runs its own executor independently; nodes exchange workflow outputs via dedicated skills.

## How It Works

Nodes connect via Erlang distribution using EPMD (Erlang Port Mapper Daemon). Each node must share the same `CLUSTER_COOKIE`.

```
Node A (alexclaw@node1.local)        Node B (alexclaw@node2.local)
  ├── Executor                         ├── Executor
  ├── SkillRegistry                    ├── SkillRegistry
  ├── Telegram Gateway                 ├── Discord Gateway
  └── send_to_workflow ──RPC──────────> receive_from_workflow
```

## Cluster Manager

`AlexClaw.Cluster.Manager` is a GenServer that:

- Auto-registers itself and connecting nodes via `:net_kernel.monitor_nodes/1`
- Pings known nodes from the DB 5 seconds after boot
- Updates node status on `:nodeup`/`:nodedown` events
- Handles incoming remote workflow triggers

## Cross-Node Workflow Flow

1. Node A runs a workflow with a `send_to_workflow` step
2. `send_to_workflow` calls `:rpc.call(node_b, ClusterManager, :receive_workflow_data, ...)` with a 5s timeout
3. Node B's ClusterManager validates the gate (step 1 must be `receive_from_workflow`)
4. The target workflow is spawned via `Task.Supervisor`
5. `receive_from_workflow` receives the data as input with `_source_node` in config

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

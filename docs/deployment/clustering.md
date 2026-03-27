# Multi-Node Deployment

AlexClaw supports multi-node BEAM clustering for distributed workflow execution.

## Setup

A `docker-compose_swarm.yml` is included for multi-node testing:

```bash
docker compose -f docker-compose_swarm.yml up -d
```

Each node needs:

| Variable | Example |
|---|---|
| `NODE_NAME` | `alexclaw@node1.local`, `alexclaw@node2.local` |
| `CLUSTER_COOKIE` | Same value on all nodes |

## Cookie Security

```bash
# Generate a secure cookie
openssl rand -base64 32
```

!!! danger "Protect the cookie"
    The cluster cookie grants full access to any node in the cluster. Treat it like `SECRET_KEY_BASE`. Never expose EPMD port 4369 to the internet.

## Network Requirements

| Port | Protocol | Purpose |
|---|---|---|
| 4369 | TCP | EPMD (node discovery) |
| Dynamic high range | TCP | BEAM distribution |
| 5001 | TCP | HTTP (web UI + MCP) |

All inter-node traffic should be on a private network, VPC, or Docker network.

## Gateway Assignment

In cluster mode, messaging gateways only start on their assigned node:

- Set `telegram.node` / `discord.node` in Admin > Config
- Or enable from a node — it auto-assigns itself

## Cross-Node Workflows

See [Architecture: Clustering](../architecture/clustering.md) for the `send_to_workflow` / `receive_from_workflow` pattern.

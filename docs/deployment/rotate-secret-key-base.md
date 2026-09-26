# Rotating SECRET_KEY_BASE

Since 0.4.0 no stored value is encrypted with `SECRET_KEY_BASE`: every
credential is a secret in OpenBao. Changing the key is an edit and a restart,
with no data to re-encrypt.

What it still keys, and what a change does:

- session cookies and page tokens are signed with it — **everyone signs in
  again**, and every open admin session ends;
- the TOTP replay guard keeps a keyed fingerprint of the last accepted code —
  it is reset, which only means the last code could be offered once more
  within its 90 seconds;
- nothing stored becomes unreadable.

**Upgrading from 0.3.x:** keep the same `SECRET_KEY_BASE` until the first
start of 0.4.0 has run. That start reads what 0.3.x encrypted under it, once,
and moves it into OpenBao. To rotate the key, do it before the upgrade, with
0.3.x's rotation procedure, or after the first start of 0.4.0.

Run every command from the directory holding `docker-compose.yml` and `.env`.

## 1. Generate the new key

```bash
openssl rand -base64 48
```

## 2. Put it in `.env`

Replace the value of `SECRET_KEY_BASE` in `.env` with the new one. The
application refuses to start with a key shorter than 64 bytes.

## 3. Restart the application

```bash
docker compose up -d alexclaw-prod
# with docker-compose_swarm.yml: docker compose -f docker-compose_swarm.yml up -d node1 node2
```

Every node of a cluster must run with the same key.

## 4. Verify

Sign in to the admin UI again. Credentials, the second factor and the MCP key
work as before.

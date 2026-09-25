# OpenBao

AlexClaw keeps its secrets in [OpenBao](https://openbao.org), which runs as its
own container beside it. AlexClaw reaches it over TLS on a private network,
authenticates with an AppRole, and never sees OpenBao's storage, keys or
configuration.

## Services

| Service | Role |
|---|---|
| `openbao` | OpenBao 2.6, pinned by digest. Non-root, read-only root filesystem, no capabilities, nothing published to the host. Raft storage on the `openbao_data` volume, a file audit log beside it. |
| `openbao-init` | One-shot, on every start of the stack: makes the TLS certificate while OpenBao is not running, then initialises OpenBao once. |
| `alexclaw-prod` | Joins the `vault` network at a fixed address, the only one OpenBao's AppRole accepts. Mounts the bootstrap volume read-only. |

The `vault` network (`10.213.63.0/24`) is internal: only these three services
join it, and it has no route out.

## What each side holds

| Where | Contents |
|---|---|
| OpenBao's data volume | Raft storage and the audit log |
| OpenBao's TLS volume | The server certificate and key, and the CA certificate |
| The unseal key directory on the host (`OPENBAO_UNSEAL_DIR`) | `key`: 32 random bytes, mounted read-only into `openbao` only |
| AlexClaw's bootstrap volume | `role_id`, `secret_id` and `ca.pem` — nothing else |

The CA that signs OpenBao's certificate exists only inside `openbao-init` while
it runs: its key is discarded, so no new certificate can be signed with it. A
new certificate, from a new CA, is made whenever the stack starts while OpenBao
is not running.

## First start

1. Make the unseal key, readable by OpenBao's user (uid 100):

    ```bash
    mkdir -p openbao/unseal
    head -c 32 /dev/urandom > openbao/unseal/key
    chmod 0440 openbao/unseal/key
    ```

    On Linux, also `sudo chown 100 openbao/unseal/key`. Keep a copy offline:
    without it, OpenBao's data cannot be decrypted.

2. Start the stack: `docker compose up -d`. `openbao-init` makes the
   certificate and exits with an error saying OpenBao is not initialised —
   that step needs a terminal.

3. Initialise, once, at a terminal:

    ```bash
    docker compose run --rm openbao-init
    ```

    It prints the recovery key once and waits until `SAVED` is typed, confirming
    the recovery key and the unseal key file are stored offline. It then
    enables kv-v2 at `secret/` and transit (key `alexclaw`), writes AlexClaw's
    policy, creates the AppRole bound to AlexClaw's address, writes the
    bootstrap files, and revokes the root token.

Later starts find OpenBao initialised and change nothing.

## AlexClaw's permissions

The `alexclaw` policy allows exactly:

- create, read and update under `secret/data/alexclaw/*`;
- encrypt and decrypt with the transit key `alexclaw`.

Anything else is refused by OpenBao. AlexClaw's token lives only in the memory
of the `AlexClaw.Vault` process, lasts an hour, is renewed before it expires,
and is replaced by a new login when renewal fails. The AppRole accepts a login,
and its tokens are honoured, only from AlexClaw's address on the `vault`
network.

## When OpenBao is unavailable

AlexClaw keeps running. Every read, write, encryption or decryption returns
`{:error, :vault_unavailable}`, the client logs in again in the background, and
a failure is logged with what failed — never a value.

## The test stack

`openbao-test` and `openbao-test-init` are the same services with a tmpfs for
OpenBao's data: every run starts an empty server and initialises it
unattended. The test stack's `vault` network is `10.213.64.0/24`, and its
unseal key is a committed test fixture.

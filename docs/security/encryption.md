# Encryption at Rest

Since 0.4.0 AlexClaw keeps no credential in its database. API keys, bot
tokens, OAuth secrets, step and resource credentials and LLM provider keys are
secrets in OpenBao, which encrypts them; the database holds references to them.
Nothing is encrypted with a key derived from `SECRET_KEY_BASE` any more.

| Where | What the database holds |
|---|---|
| a declared secret setting (`telegram.bot_token`, `github.token`, …) | the setting's name; the value is in OpenBao |
| `mcp.api_key` | an HMAC fingerprint of the key, never the key |
| `auth.admin_password_hash` | a salted PBKDF2-HMAC-SHA256 hash |
| a workflow step's `config`, a resource's `metadata` | references to secrets, bound to the host they are sent to |
| `llm_providers.credentials` | references for the API key and each header value; the header names stay readable |

A setting named like a credential (`api_key`, `token`, `password` or `secret`
in its key) is refused unless it is a declared secret setting. A skill whose
configuration has a credential-like key must declare it with
`secret_config_keys/0`.

## Upgrading from 0.3.x

0.3.x encrypted sensitive settings and some credentials under
`SECRET_KEY_BASE`. The first start of 0.4.0 reads them once, under the same
key, and moves them into OpenBao; keep `SECRET_KEY_BASE` unchanged until it has
run. An export made by 0.3.x is restored into 0.3.x and upgraded: 0.4.0
refuses a file holding values 0.3.x encrypted.

## Changing SECRET_KEY_BASE

It signs sessions and keys the TOTP replay guard; changing it ends every login
and makes nothing unreadable. See
[Rotating SECRET_KEY_BASE](../deployment/rotate-secret-key-base.md).

The details, and every security claim, are in
[SECURITY.md](https://github.com/thatsme/AlexClaw/blob/main/SECURITY.md).

# Encryption at Rest

Sensitive configuration values (API keys, OAuth tokens, webhook secrets) are encrypted in PostgreSQL using AES-256-GCM.

## How It Works

1. The encryption key is derived from `SECRET_KEY_BASE` using HKDF-SHA256
2. The derived key is cached in `:persistent_term` for fast access
3. Each value gets a unique random IV (initialization vector)
4. Encryption/decryption happens transparently in `AlexClaw.Config`

## What's Encrypted

Any setting with `sensitive: true` is encrypted:

| Setting | Category |
|---|---|
| `GEMINI_API_KEY` | llm |
| `ANTHROPIC_API_KEY` | llm |
| `TELEGRAM_BOT_TOKEN` | telegram |
| `DISCORD_BOT_TOKEN` | discord |
| `mcp.api_key` | mcp |
| `github.token` | github |
| `github.webhook_secret` | github |
| `google.oauth.client_secret` | google |
| `google.oauth.refresh_token` | google |

## Boot Sequence

1. `EncryptExisting` migration runs idempotently — encrypts any plaintext sensitive values
2. `Config.init()` loads all settings into ETS with decrypted values
3. Application code reads from ETS — never sees ciphertext

## Admin UI

Sensitive values are partially masked in the Config page (e.g., `sk-ant-...****`). The full value is only visible during edit.

## Key Rotation

If you change `SECRET_KEY_BASE`:

1. All encrypted values become unreadable
2. Re-seed from environment variables, or
3. Export values before rotating the key

!!! danger "Protect SECRET_KEY_BASE"
    This is the root key for all encryption. Store it securely in your `.env` file and never commit it to version control. Generate with `openssl rand -base64 64`.

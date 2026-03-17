# Security Policy

## Reporting a Vulnerability

Please do NOT open a public GitHub issue for security vulnerabilities.

Contact: development@securtel.net
Expected response: within 72 hours
Coordinated disclosure: 90 days before public disclosure requested

---

## Authentication

AlexClaw includes built-in session-based authentication. The web interface
is fully protected — all routes except `/login` require an authenticated session.
There is no anonymous access to any admin functionality.

Authentication is configured via the `ADMIN_PASSWORD` environment variable
(see `.env.example`). `ADMIN_PASSWORD` is always required — if it is not set,
the login page will show an error and no access is granted.

---

## Two-Factor Authentication

TOTP-based 2FA is available for sensitive Telegram commands.
Setup via `/setup 2fa` — compatible with any TOTP authenticator
(Google Authenticator, Authy, etc.).

Workflows can be marked `Requires 2FA` in the admin UI,
requiring code verification before execution.

---

## Telegram Gateway Security

AlexClaw only responds to messages from the configured `TELEGRAM_CHAT_ID`.
Messages from any other chat ID are silently ignored.
Do not share your bot token — anyone with the token can send commands
if they know or guess your chat ID.

---

## GitHub Webhook Verification

The `/webhooks/github` endpoint verifies all incoming payloads using
HMAC-SHA256 with `Plug.Crypto.secure_compare` for timing-safe comparison.
Webhooks without a valid signature are rejected with 401.
If no webhook secret is configured, all webhooks are rejected.
Set `github.webhook_secret` in Admin > Config (GitHub category).

---

## Web Automator Sidecar

The web-automator sidecar runs a real browser with network access.
Automation recipes execute arbitrary browser actions — review recorded
recipes before assigning them to scheduled workflows.
The noVNC interface (port 6080) should never be exposed publicly.

---

## Encryption at Rest

Sensitive configuration values (API keys, tokens, OAuth secrets) are encrypted
at the application level using **AES-256-GCM** before being stored in PostgreSQL.

- Encryption key is derived from `SECRET_KEY_BASE` via HKDF-SHA256
- Each value gets a unique 12-byte random IV — identical plaintext produces different ciphertext
- Encrypted values are stored with an `enc:` prefix (base64-encoded IV + ciphertext + GCM tag)
- Decryption happens transparently on boot (ETS cache holds plaintext for runtime use)
- The admin UI displays masked values — never raw ciphertext or full plaintext

**Sensitive keys** (automatically marked and encrypted):
`telegram.bot_token`, `llm.gemini_api_key`, `llm.anthropic_api_key`,
`github.token`, `github.webhook_secret`, `google.oauth.client_secret`,
`google.oauth.refresh_token`

**Important:** If you change `SECRET_KEY_BASE`, all encrypted settings become
unreadable. You will need to re-enter API keys and tokens via the admin UI
or environment variables and restart.

---

## Known Limitations and Design Decisions

**LLM prompts may contain user data.**
Workflow steps send data to external LLM providers (Anthropic, Google Gemini).
Review which providers are enabled and their data retention policies before
processing sensitive information.

**Built-in login rate limiting.**
Failed login attempts are tracked per IP using ETS. After 5 failures
(configurable), the IP is blocked for 15 minutes (configurable).
Limits are adjustable at runtime from the Config UI without restart.

---

## Deployment Hardening

- Run behind a reverse proxy with TLS — never expose port 5001 directly
- Set a strong random `SECRET_KEY_BASE` (`mix phx.gen.secret`) — this is also the encryption key material for sensitive config values
- Set `ADMIN_PASSWORD` to a strong random value
- Restrict PostgreSQL to localhost or internal network only
- Built-in login rate limiting is active by default (configurable via Config UI)
- Never expose noVNC port (6080) publicly — it provides unauthenticated browser access

---

## Scope

AlexClaw is designed as a single-user personal agent. Multi-user access
control is not in scope. The authentication model assumes a single trusted
operator.

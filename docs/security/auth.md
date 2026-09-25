# Authentication & 2FA

## Web Authentication

All routes except `/login`, `/health`, and `/mcp` require an authenticated session.

- Password stored as `ADMIN_PASSWORD` environment variable (seeded to DB on first boot)
- Each login is a row in the `admin_sessions` table, checked on every request and
  every LiveView connection, on whichever node serves it. The cookie holds an
  identifier; the table holds only its SHA-256.
- A login lasts eight hours from sign-in, busy or idle.
- Changing `ADMIN_PASSWORD` ends every login: each row records a keyed
  fingerprint of the password it was opened with.
- Logout ends that login and closes its open pages.
- Redeeming a recovery code, or turning 2FA off, ends every other login. Turning
  2FA off from a gateway ends all of them. Each is recorded in the audit log.
- **Sign out everywhere** (Services page, needs editing unlocked) ends every
  login, including the one that asked.

## Login Rate Limiting

ETS-based rate limiting protects against brute-force attacks:

- Tracks failed attempts per IP address within a sliding window
- After 5 failures (configurable) inside a 5-minute window (configurable): blocks the IP for 15 minutes (configurable)
- Failures older than the window are discarded rather than accumulating, so an IP is never one attempt away from a block indefinitely
- A GenServer runs periodic purge cycles, clearing both expired blocks and stale counts
- All three limits are adjustable at runtime via **Admin > Config**:
  `auth.rate_limit.max_attempts`, `auth.rate_limit.window_seconds`,
  `auth.rate_limit.block_duration_seconds`

## Two-Factor Authentication (2FA)

TOTP-based 2FA using authenticator apps (Google Authenticator, Authy, etc.).

### Setup

1. Send `/setup 2fa` to your Telegram/Discord bot
2. Scan the QR code with your authenticator app
3. Confirm with `/confirm 2fa <code>`

### Protected Operations

When 2FA is enabled, these operations require TOTP verification:

| Operation | Where |
|---|---|
| Skill load/unload/reload | Admin UI only (the code can be answered from Telegram/Discord) |
| Shell command execution | `/shell` from Telegram/Discord |
| Workflows marked "Requires 2FA" | Telegram/Discord **and** the Run button in the Admin UI |
| Disabling 2FA | Admin UI only, Services page, with a current authenticator code |

These **fail closed**: when TOTP is not configured they are refused outright,
not allowed through. Set 2FA up before relying on any of them.

The gateway commands name a file already present in the skills volume — code
itself cannot be uploaded from a messaging app.

### Challenge Limits

A challenge is a two-minute window in which any six digits can be tried, so both
the count and the reuse of codes are bounded:

- **Three wrong codes cancel the challenge.** The action must be triggered
  again, which mints a fresh challenge with a fresh count.
- **A code is accepted once.** The time of the last accepted code is persisted
  and passed to the verifier, which refuses any code from a period already
  used — so a code observed in transit cannot be replayed inside its
  30-second window. The marker survives a restart and is not readable through
  the configuration API.

### Cross-Channel Verification

Admin UI actions that require 2FA are verified via Telegram or Discord — the TOTP challenge is sent to the messaging gateway, not displayed in the browser. This prevents session hijacking from granting full access.

### Management Commands

```
/setup 2fa        → Generate secret and QR code
/confirm 2fa CODE → Confirm 2FA setup
```

Two-factor authentication is turned off from the Services page only, with a
current authenticator code.

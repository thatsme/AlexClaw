# Authentication & 2FA

## Web Authentication

All routes except `/login`, `/health`, and `/mcp` require an authenticated session.

- The first successful login checks `ADMIN_PASSWORD` and stores a salted
  PBKDF2-HMAC-SHA256 hash (600,000 iterations); from then on the variable is
  ignored. The hash is kept in the database, not in OpenBao, so login works
  while OpenBao is unavailable. An unreadable hash refuses every login.
- Each login is a row in the `admin_sessions` table, checked on every request and
  every LiveView connection, on whichever node serves it. The cookie holds an
  identifier; the table holds only its SHA-256.
- A login lasts eight hours from sign-in, busy or idle.
- A new password hash ends every login: each row records a keyed
  fingerprint of the hash it was opened with.
- Logout ends that login and closes its open pages.
- Redeeming a recovery code, or turning 2FA off, ends every other login. Each
  is recorded in the audit log.
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

1. In the admin UI, open **Services → Two-factor authentication** and choose
   *Set up*
2. Scan the QR code with your authenticator app, or type the key shown
3. Confirm with a code from the app

Setting up is refused while 2FA is on: the active factor is replaced only by
turning it off first, which takes a current code. The secret is never sent over
a chat.

The key is created and kept by OpenBao's TOTP engine, which checks every code;
AlexClaw stores no part of it. Recovery codes are stored as HMACs under an
OpenBao transit key. While OpenBao is unavailable, no code can be checked.

### Protected Operations

When 2FA is enabled, these operations need a code of their own:

| Operation | Where |
|---|---|
| Skill load and reload | Admin UI, Skills page |
| Database restore | Admin UI, Database page |
| Workflows marked "Requires 2FA" | the Run button in the Admin UI, or `/run` on Telegram/Discord |
| Workflows with a `shell`, `coder`, `db_backup` or `web_automation` step | the Run button in the Admin UI (never a chat); a schedule runs them without one |
| Disabling 2FA, generating recovery codes | Admin UI only, Services page; disabling takes a current authenticator code or a recovery code |

Every other change — configuration, providers, resources, workflows, skill
unload, recordings — needs an elevation: one code, good for fifteen minutes.

These **fail closed**: when TOTP is not configured they are refused outright,
not allowed through. Set 2FA up before relying on any of them. Code cannot be
uploaded from a messaging app.

### Challenge Limits

A challenge is a two-minute window in which any six digits can be tried, so both
the count and the reuse of codes are bounded:

- **Three wrong codes cancel the challenge.** The action must be triggered
  again, which mints a fresh challenge with a fresh count.
- **A code is accepted once.** OpenBao, which checks the codes, refuses one
  it has already accepted; because that memory is lost when OpenBao
  restarts, AlexClaw also refuses the last accepted code for 90 seconds. It
  keeps a keyed fingerprint of it, never the code, and the guard survives a
  restart.

### Where a Code Is Typed

A code is typed on the admin UI page that asked for it. A protected workflow
run (without a privileged step) is also prompted on the configured gateways,
and a code answered there approves that run and nothing else.

### Management Commands

```
/setup 2fa        → refused: answers that set-up is in the admin UI
/disable 2fa      → refused: answers that turning it off is in the admin UI
```

Two-factor authentication is turned off from the Services page only, with a
current authenticator code or, when the authenticator is lost, a recovery
code (audited as a recovery code). Turning it off wipes every recovery code.
`/disable 2fa` on a gateway is refused.

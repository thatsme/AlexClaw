# Authentication & 2FA

## Web Authentication

All routes except `/login`, `/health`, and `/mcp` require an authenticated session.

- Session-based authentication using Phoenix sessions
- Password stored as `ADMIN_PASSWORD` environment variable (seeded to DB on first boot)
- Sessions expire based on configurable timeout

## Login Rate Limiting

ETS-based rate limiting protects against brute-force attacks:

- Tracks failed attempts per IP address
- After 5 failures (configurable): blocks the IP for 15 minutes (configurable)
- A GenServer runs periodic purge cycles to clean expired entries
- All limits adjustable at runtime via **Admin > Config**

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
| Skill load/unload/reload | Admin UI |
| Shell command execution | Telegram/Discord |
| Workflows marked "Requires 2FA" | Telegram/Discord |

### Cross-Channel Verification

Admin UI actions that require 2FA are verified via Telegram or Discord — the TOTP challenge is sent to the messaging gateway, not displayed in the browser. This prevents session hijacking from granting full access.

### Management Commands

```
/setup 2fa        → Generate secret and QR code
/confirm 2fa CODE → Confirm 2FA setup
/disable 2fa      → Disable 2FA
```

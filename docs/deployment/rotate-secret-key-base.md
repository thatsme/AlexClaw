# Rotating SECRET_KEY_BASE

`SECRET_KEY_BASE` is more than a cookie-signing key in AlexClaw. Sensitive settings are stored encrypted with a key derived from it, the TOTP secret included. **Changing it without re-encrypting them makes them unreadable.** Two-factor authentication stops working, and so does every stored credential.

The rotation re-encrypts every encrypted setting from the old key to the new one, in a single database transaction:

- every value is decrypted with the old key, re-encrypted with the new one, and checked to decrypt again before it is written;
- if any value cannot be decrypted with the old key, **nothing is changed** and the rotation says which setting;
- every login is ended, and the rotation is recorded in the audit log.

Running it a second time is refused: after a rotation the old key decrypts nothing.

What else changes with the key: everyone signs in again, because session cookies and page tokens are signed with it. Recovery codes are unaffected.

Requires 0.3.34 or later, which has the `migrate` service. Run every command from the directory holding `docker-compose.yml` and `.env`.

## 1. Back up

```bash
docker exec alexclaw-db-prod pg_dump -U <owner> -Fc alex_claw_prod \
  > ~/backups/alex_claw_prod-$(date +%Y%m%d-%H%M%S).dump
```

## 2. Generate the new key

```bash
openssl rand -base64 48
```

Keep it somewhere safe until step 5. Keep the current value from `.env` too; step 4 needs both.

## 3. Stop the application

A running node keeps the old key in memory and would go on using it. Stop every application container; the database stays up.

```bash
docker compose stop alexclaw-prod
# with docker-compose_swarm.yml: docker compose -f docker-compose_swarm.yml stop node1 node2
```

## 4. Re-encrypt

`read -rs` keeps both values out of the shell history:

```bash
read -rs OLD_SECRET_KEY_BASE   # paste the current value, then Enter
read -rs NEW_SECRET_KEY_BASE   # paste the new value, then Enter

docker compose run --rm --no-deps \
  -e OLD_SECRET_KEY_BASE="$OLD_SECRET_KEY_BASE" \
  -e SECRET_KEY_BASE="$NEW_SECRET_KEY_BASE" \
  migrate bin/alex_claw eval "AlexClaw.Release.rekey()"
```

On success it prints `Re-encrypted <n> settings under the new SECRET_KEY_BASE.`

If it prints `SECRET_KEY_BASE rotation refused: ...`, nothing was changed. The usual cause is an old value that is not the one currently in `.env`. Do not continue to step 5.

## 5. Switch `.env` to the new key

Set `SECRET_KEY_BASE` in `.env` to the new value, then:

```bash
unset OLD_SECRET_KEY_BASE NEW_SECRET_KEY_BASE
docker compose up -d
```

## 6. Verify

Sign in. Everyone has to, since every login was ended. Then unlock editing with a code from the authenticator: a code that works shows the TOTP secret decrypted under the new key. The audit log (Policies → Audit) shows `SECRET_KEY_BASE rotated: <n> encrypted settings re-encrypted, <m> logins ended`.

## If something goes wrong

- **The rotation was refused**: nothing changed. Start the application with the unchanged `.env`.
- **The application started with the new key before the rotation ran**: encrypted settings cannot be read, and 2FA fails. Stop the application, put the old key back in `.env`, and start again from step 3.
- **The backup from step 1** restores the database as it was: see [Upgrading to 0.3.34](upgrade-0.3.34.md#restoring-after-0334).

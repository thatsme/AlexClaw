# Rotating SECRET_KEY_BASE

`SECRET_KEY_BASE` is more than a cookie-signing key in AlexClaw. Sensitive settings and stored credentials (LLM provider keys and headers, and step secrets written by 0.3.x that the 0.4.0 upgrade has not moved to OpenBao yet) are encrypted with a key derived from it, the TOTP secret included. **Changing it without re-encrypting them makes them unreadable.** Two-factor authentication stops working, and so does every stored credential.

The rotation re-encrypts every encrypted value from the old key to the new one, in a single database transaction:

- every value is decrypted with the old key, re-encrypted with the new one, and checked to decrypt again before it is written;
- if any value cannot be decrypted with the old key, **nothing is changed** and the rotation says which setting or row;
- every login is ended, and the rotation is recorded in the audit log.

Running it a second time is refused: after a rotation the old key decrypts nothing.

What else changes with the key: everyone signs in again, because session cookies and page tokens are signed with it. Recovery codes are unaffected.

Requires 0.3.34 or later. Run every command from the directory holding `docker-compose.yml` and `.env`.

## 1. Back up

```bash
mkdir -p ~/backups
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

The rotation runs in a one-off application container, as the application role. It is never run in the `migrate` service: that one holds the database owner's credentials, and those never share a container with the key. `read -rs` keeps both values out of the shell history:

```bash
read -rs OLD_SECRET_KEY_BASE   # paste the current value, then Enter
read -rs NEW_SECRET_KEY_BASE   # paste the new value, then Enter

docker compose run --rm --no-deps --entrypoint bin/alex_claw \
  -e OLD_SECRET_KEY_BASE="$OLD_SECRET_KEY_BASE" \
  -e SECRET_KEY_BASE="$NEW_SECRET_KEY_BASE" \
  alexclaw-prod eval "AlexClaw.Release.rekey()"
# with docker-compose_swarm.yml: the same, with -f docker-compose_swarm.yml and node1
```

On success it prints `Re-encrypted <n> values under the new SECRET_KEY_BASE.`

If it prints `SECRET_KEY_BASE rotation refused: ...`, nothing was changed. The usual cause is an old value that is not the one currently in `.env`. Do not continue to step 5.

## 5. Switch `.env` to the new key

Set `SECRET_KEY_BASE` in `.env` to the new value, then:

```bash
unset OLD_SECRET_KEY_BASE NEW_SECRET_KEY_BASE
docker compose up -d
```

## 6. Verify

Sign in. Everyone has to, since every login was ended. Then unlock editing with a code from the authenticator: a code that works shows the TOTP secret decrypted under the new key. The audit log (Policies → Audit) shows `SECRET_KEY_BASE rotated: <n> encrypted values re-encrypted, <m> logins ended`.

## If something goes wrong

- **The rotation was refused**: nothing changed. Start the application with the unchanged `.env`.
- **The application does not start after the key changed**: the log says `These stored values do not decrypt under this SECRET_KEY_BASE` and names them. The key changed without a rotation. Put the old key back in `.env`, start, and rotate from step 1. Nothing is lost while the old key exists.
- **The backup from step 1** restores the database as it was: see [Upgrading to 0.3.34](upgrade-0.3.34.md#restoring-after-0334).

## Lost key

This is not a rotation. It is for the case where the previous `SECRET_KEY_BASE` is gone for good, so the values encrypted under it can never be read again. The application refuses to start while any are stored, and names them.

The procedure clears exactly those values: sensitive settings (the TOTP secret among them), provider API keys and header values, and step secrets. It keeps everything that still decrypts. It runs in a one-off application container, with the application stopped.

1. **Back up**, as in step 1. The backup still holds the lost values, should the key turn up again.

2. **Stop the application**, as in step 3.

3. **List what would be discarded.** This changes nothing:

   ```bash
   docker compose run --rm --no-deps --entrypoint bin/alex_claw \
     alexclaw-prod eval "AlexClaw.Release.discard_undecryptable()"
   ```

   It prints each value's location, never the value (for example `settings telegram.bot_token`, `llm_providers 3 api_key`, `workflow_steps 12 config.bot_token`), and the confirmation to use, `DISCARD <n>`.

4. **Discard them** with that exact confirmation. Anything else, including a count that no longer matches, is refused with nothing changed:

   ```bash
   docker compose run --rm --no-deps --entrypoint bin/alex_claw \
     alexclaw-prod eval 'AlexClaw.Release.discard_undecryptable("DISCARD <n>")'
   ```

   It clears the values in one transaction and writes an audit row naming them: `undecryptable values discarded (SECRET_KEY_BASE lost): ...`.

5. **Start the application**, and enter the discarded credentials again: sensitive settings under Config, provider keys under LLM, step secrets in each workflow step. If the TOTP secret was discarded, set up two-factor authentication again under Services. Until then, admin changes stay read-only.

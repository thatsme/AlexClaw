defmodule AlexClaw.Repo.Migrations.RepairOrphanedTotpFlag do
  use Ecto.Migration

  # `auth.totp.enabled = true` with no secret behind it is not a configured
  # second factor — it is a locked control plane. The instance reports 2FA as
  # on, refuses every code because there is nothing to compare against, and
  # hides the setup button because the page asks the same question. There is no
  # way out of it from the browser.
  #
  # It shipped: an instance upgraded from 0.3.21 arrived in exactly this state
  # and had to be cleared by hand. The flag had presumably been true since
  # before the secret was ever stored.
  #
  # Clearing the flag is the whole repair. The setup screen renders again, the
  # operator enrols, and confirm_setup/1 sets the flag back to true — this time
  # with a secret written in the same breath.
  #
  # execute/1 rather than repo().query!/1: a migration that goes through the
  # repo waits on a sandbox checkout that never comes, and takes the whole test
  # suite with it.
  def up do
    execute("""
    UPDATE settings
       SET value = 'false',
           updated_at = NOW() AT TIME ZONE 'utc'
     WHERE key = 'auth.totp.enabled'
       AND value = 'true'
       AND NOT EXISTS (
         SELECT 1
           FROM settings secret
          WHERE secret.key = 'auth.totp.secret'
            AND secret.value IS NOT NULL
            AND secret.value <> ''
       )
    """)
  end

  # Turning 2FA back on for an instance that has no secret would restore the
  # lockout, so there is nothing to undo here.
  def down, do: :ok
end

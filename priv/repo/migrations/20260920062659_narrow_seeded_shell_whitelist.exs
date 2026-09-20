defmodule AlexClaw.Repo.Migrations.NarrowSeededShellWhitelist do
  use Ecto.Migration

  # 0.3.22 narrowed the shell skill's compiled allowlist but not the seeder's
  # copy of it, and a seeded row wins over the compiled default. Every database
  # seeded before 0.3.26 therefore still grants what 0.3.22 withdrew.
  #
  # Only a row that still holds the original seeded list is rewritten. A list an
  # operator has edited is theirs and is left exactly as it is — the allowlist
  # decides what runs in the container, so it is not something a migration may
  # quietly redecide. Config.Loader reports at boot when a list it left alone
  # still carries a withdrawn prefix.
  @original ~s(["df","free","ps","uptime","cat /proc","ping","nslookup","curl","bin/alex_claw","uname","whoami","hostname","date","ls","git"])
  @narrowed ~s(["df","free","uptime","uname","whoami","hostname","date","ls"])

  # Raw SQL through the runner's own connection. Reading the row into Elixir
  # with repo().query!/1 would check out a second connection, which deadlocks
  # under the sandbox pool the test environment uses.
  def change, do: execute(rewrite(@original, @narrowed), rewrite(@narrowed, @original))

  # Compared as the set of parsed entries, so formatting and ordering in the
  # stored JSON do not matter. IS JSON ARRAY guards the cast: a row holding
  # something that is not a JSON array is left alone rather than failing here.
  defp rewrite(from, to) do
    """
    UPDATE settings
       SET value = '#{to}',
           updated_at = NOW() AT TIME ZONE 'utc'
     WHERE key = 'shell.whitelist'
       AND CASE
             WHEN value IS JSON ARRAY THEN
               (SELECT array_agg(DISTINCT e ORDER BY e)
                  FROM jsonb_array_elements_text(value::jsonb) AS e)
               IS NOT DISTINCT FROM
               (SELECT array_agg(DISTINCT e ORDER BY e)
                  FROM jsonb_array_elements_text('#{from}'::jsonb) AS e)
             ELSE false
           END
    """
  end
end

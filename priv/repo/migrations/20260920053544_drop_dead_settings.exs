defmodule AlexClaw.Repo.Migrations.DropDeadSettings do
  use Ecto.Migration

  # Settings nothing reads. Each was seeded on first boot and has been editable
  # in Admin > Config ever since, so each one is a control that promises an
  # effect the code never had. They are removed rather than wired:
  #
  #   llm.limit.*             — superseded by llm_providers.daily_limit, which
  #                             is the value LLM.Real actually enforces
  #   skill.github_review.*   — github_security_review fetches diffs and calls
  #   github.security_focus     no LLM; the analysis lives in the following
  #                             llm_transform step, which has its own fields
  #   discord.guild_id        — the gateway dispatches by channel, not guild
  #   cluster.enabled         — clustering follows registered nodes; the flag
  #                             defaulted to "false" while clustering worked
  #   prompts.rss.scoring     — a per-item template from before scoring became
  #                             one batched call; the batched call reads
  #                             prompts.rss.interests, which is seeded instead
  @dead ~w(
    llm.limit.gemini_flash
    llm.limit.gemini_pro
    llm.limit.haiku
    llm.limit.sonnet
    skill.github_review.tier
    skill.github_review.provider
    github.security_focus
    discord.guild_id
    cluster.enabled
    prompts.rss.scoring
  )

  # Raw SQL rather than the Setting schema: a migration must keep working when
  # the schema changes. Irreversible by design — restoring a row would restore
  # the false promise, and the Seeder no longer knows these keys.
  def up do
    keys = Enum.map_join(@dead, ", ", &"'#{&1}'")
    execute("DELETE FROM settings WHERE key IN (#{keys})")
  end

  def down do
    raise Ecto.MigrationError,
      message: "drop_dead_settings is irreversible: these keys have no readers to restore"
  end
end

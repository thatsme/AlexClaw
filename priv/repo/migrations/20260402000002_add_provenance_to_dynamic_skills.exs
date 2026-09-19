defmodule AlexClaw.Repo.Migrations.AddProvenanceToDynamicSkills do
  use Ecto.Migration

  # How a skill got here, and what authorised it. Generated skills that stay
  # inside the call allowlist are approved by containment rather than by a TOTP
  # code, so the pair has to be recorded to re-check them on boot.
  def up do
    alter table(:dynamic_skills) do
      add(:origin, :string, null: false, default: "upload")
      add(:approval, :string, null: false, default: "totp")
    end

    # Everything already loaded predates generation, and was approved by TOTP.
    execute("UPDATE dynamic_skills SET origin = 'upload', approval = 'totp'")
  end

  def down do
    alter table(:dynamic_skills) do
      remove(:origin)
      remove(:approval)
    end
  end
end

defmodule AlexClaw.Repo.Migrations.StandardizeTimestampsToUtc do
  use Ecto.Migration

  @tables ~w(llm_providers workflows workflow_steps workflow_runs resources)a

  def change do
    for table <- @tables do
      alter table(table) do
        modify :inserted_at, :utc_datetime, from: :naive_datetime
        modify :updated_at, :utc_datetime, from: :naive_datetime
      end
    end

    alter table(:workflow_resources) do
      modify :inserted_at, :utc_datetime, from: :naive_datetime
    end
  end
end

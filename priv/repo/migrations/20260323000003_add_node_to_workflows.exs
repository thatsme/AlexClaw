defmodule AlexClaw.Repo.Migrations.AddNodeToWorkflows do
  use Ecto.Migration

  def change do
    alter table(:workflows) do
      add :node, :string
    end
  end
end

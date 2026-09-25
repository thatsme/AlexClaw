defmodule AlexClaw.Repo.Migrations.AddDefinitionToWorkflowRuns do
  @moduledoc """
  A run keeps the definition it ran: each step's position, name, skill,
  config (secret values replaced by a placeholder), routes and input_from, as
  they were when the run started. Runs from before this column have none.
  """
  use Ecto.Migration

  def change do
    alter table(:workflow_runs) do
      add(:definition, :map)
    end
  end
end

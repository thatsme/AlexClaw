defmodule AlexClaw.Repo.Migrations.UniqueStepPosition do
  @moduledoc """
  Routes and input_from point at step positions, so two steps of one workflow
  may never share a position: the plain (workflow_id, position) index becomes
  a unique one.
  """
  use Ecto.Migration

  def up do
    drop(index(:workflow_steps, [:workflow_id, :position]))
    create(unique_index(:workflow_steps, [:workflow_id, :position]))
  end

  def down do
    drop(index(:workflow_steps, [:workflow_id, :position]))
    create(index(:workflow_steps, [:workflow_id, :position]))
  end
end

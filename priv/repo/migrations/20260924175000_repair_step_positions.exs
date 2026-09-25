defmodule AlexClaw.Repo.Migrations.RepairStepPositions do
  @moduledoc """
  Until 0.3.55 two steps of one workflow could share a position, and the
  unique index that follows this migration would fail on such a database.
  Each workflow with a duplicate is renumbered 1..n by (position, id), its
  references rewritten (see `AlexClaw.Workflows.PositionRepair`), disabled
  and named in the log: a step that shared a position never ran, and would
  run now.
  """
  use Ecto.Migration

  require Logger

  alias AlexClaw.Workflows.PositionRepair

  def up do
    %{updates: updates, workflows: workflows} = PositionRepair.plan(steps())
    Enum.each(updates, &apply_update/1)
    disable(workflows)
  end

  def down, do: :ok

  defp steps do
    %{rows: rows} =
      repo().query!("SELECT id, workflow_id, position, routes, input_from FROM workflow_steps")

    Enum.map(rows, fn [id, workflow_id, position, routes, input_from] ->
      %{
        id: id,
        workflow_id: workflow_id,
        position: position,
        routes: routes,
        input_from: input_from
      }
    end)
  end

  defp apply_update(%{id: id, position: position, routes: routes, input_from: input_from}) do
    repo().query!(
      "UPDATE workflow_steps SET position = $1, routes = $2, input_from = $3 WHERE id = $4",
      [position, routes, input_from, id]
    )
  end

  defp disable([]), do: :ok

  defp disable(ids) do
    %{rows: rows} =
      repo().query!(
        "UPDATE workflows SET enabled = false WHERE id = ANY($1) RETURNING id, name",
        [ids]
      )

    Enum.each(rows, fn [id, name] ->
      Logger.warning(
        "Workflow #{id} (#{name}) had two steps at one position: renumbered and disabled. " <>
          "Check its routes before enabling it."
      )
    end)
  end
end

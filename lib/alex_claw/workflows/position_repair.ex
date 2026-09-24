defmodule AlexClaw.Workflows.PositionRepair do
  @moduledoc """
  The repair of duplicate step positions, computed without touching the
  database: step rows in, updates out.

  Until 0.3.55 two steps of one workflow could share a position. The
  migration that makes positions unique reads the steps through its own
  connection, asks `plan/1` for the repair and applies it.

  Only a workflow that has a duplicate is touched. Its steps are numbered
  1..n by (position, id). A reference (`goto`, `input_from`) to a duplicated
  position meant the lowest-id step there — the one 0.3.54 ran — and follows
  it; any other reference follows its step. Every touched workflow is listed,
  to be disabled: a step that shared a position never ran, and would run now.
  """

  @type step :: %{
          id: integer(),
          workflow_id: integer(),
          position: integer(),
          routes: [map()] | nil,
          input_from: integer() | nil
        }
  @type update :: %{
          id: integer(),
          position: pos_integer(),
          routes: [map()],
          input_from: integer() | nil
        }

  @doc "The updates for every step of each workflow with a duplicate position, and those workflows."
  @spec plan([step()]) :: %{updates: [update()], workflows: [integer()]}
  def plan(rows) do
    touched =
      rows
      |> Enum.group_by(& &1.workflow_id)
      |> Enum.filter(fn {_workflow_id, steps} -> duplicated?(steps) end)
      |> Enum.sort()

    %{
      updates: Enum.flat_map(touched, fn {_workflow_id, steps} -> renumbered(steps) end),
      workflows: Enum.map(touched, &elem(&1, 0))
    }
  end

  defp duplicated?(steps), do: steps |> Enum.uniq_by(& &1.position) |> length() < length(steps)

  defp renumbered(steps) do
    ordered = Enum.sort_by(steps, &{&1.position, &1.id})
    numbered = Enum.with_index(ordered, 1)

    # Sorted by (position, id), the first step seen at an old position is its
    # lowest-id one: that is where a reference to the position now points.
    moved =
      numbered
      |> Enum.reverse()
      |> Map.new(fn {step, new} -> {step.position, new} end)

    Enum.map(numbered, fn {step, new} -> update(step, new, moved) end)
  end

  defp update(step, new, moved) do
    %{
      id: step.id,
      position: new,
      routes: Enum.map(step.routes || [], &moved_route(&1, moved)),
      input_from: moved_position(step.input_from, moved)
    }
  end

  defp moved_route(%{"goto" => goto} = route, moved) when is_integer(goto),
    do: %{route | "goto" => moved_position(goto, moved)}

  defp moved_route(route, _moved), do: route

  defp moved_position(position, moved) when is_integer(position),
    do: Map.get(moved, position, position)

  defp moved_position(other, _moved), do: other
end

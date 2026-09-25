defmodule AlexClaw.Workflows.PositionRepairTest do
  @moduledoc """
  Repairing duplicate step positions before they become unique (0.3.55).

  Until 0.3.55 two steps of one workflow could share a position (add_step
  with an explicit position, an import). The unique index would fail on such
  a database and the app would not start. A migration repairs them first,
  through its own connection: it reads the steps, `PositionRepair.plan/1`
  computes the repair — a pure function, rows in, updates out, no Repo — and
  the migration applies it.

  The rules:
  - only workflows that HAVE a duplicate are touched; any other workflow,
    gaps included, is left exactly as it is;
  - in a touched workflow, steps are numbered 1..n by (position, id): order
    kept, ties broken by id;
  - a reference (`goto`, `input_from`) to a duplicated position meant the
    lowest-id step there — the one 0.3.54 ran — and now points to its new
    position; other references follow their step; "end" and "default" stay;
  - every touched workflow is listed, to be disabled: its other steps at a
    duplicated position never ran before, and must not start running on
    upgrade until someone has looked.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  alias AlexClaw.Workflows.PositionRepair

  defp step(id, workflow_id, position, opts \\ []) do
    %{
      id: id,
      workflow_id: workflow_id,
      position: position,
      routes: Keyword.get(opts, :routes, []),
      input_from: Keyword.get(opts, :input_from)
    }
  end

  defp by_id(updates), do: Map.new(updates, &{&1.id, &1})

  test "a workflow without duplicates is untouched, gaps included" do
    rows = [step(1, 7, 1), step(2, 7, 3, routes: [%{"branch" => "on_2xx", "goto" => 1}])]

    assert %{updates: [], workflows: []} = PositionRepair.plan(rows)
  end

  test "duplicates are numbered 1..n by (position, id), order kept" do
    rows = [step(10, 1, 1), step(12, 1, 2), step(11, 1, 2), step(13, 1, 3)]

    %{updates: updates, workflows: [1]} = PositionRepair.plan(rows)
    new = updates |> by_id() |> Map.new(fn {id, u} -> {id, u.position} end)

    assert new == %{10 => 1, 11 => 2, 12 => 3, 13 => 4}
  end

  test "a reference to a duplicated position points to the lowest-id step there" do
    rows = [
      step(10, 1, 1, routes: [%{"branch" => "on_2xx", "goto" => 2}]),
      step(12, 1, 2),
      step(11, 1, 2),
      step(13, 1, 3, input_from: 2)
    ]

    %{updates: updates} = PositionRepair.plan(rows)
    u = by_id(updates)

    # step 11 (lowest id at old 2) is new 2
    assert u[10].routes == [%{"branch" => "on_2xx", "goto" => 2}]
    assert u[13].input_from == 2
  end

  test "other references follow their step; end and default stay" do
    rows = [
      step(10, 1, 1,
        routes: [
          %{"branch" => "on_2xx", "goto" => 3},
          %{"branch" => "on_4xx", "goto" => "end"},
          %{"branch" => "default", "goto" => 3}
        ]
      ),
      step(11, 1, 2),
      step(12, 1, 2),
      step(13, 1, 3)
    ]

    %{updates: updates} = PositionRepair.plan(rows)
    routes = by_id(updates)[10].routes

    # old 3 (step 13) is new 4
    assert %{"branch" => "on_2xx", "goto" => 4} in routes
    assert %{"branch" => "on_4xx", "goto" => "end"} in routes
    assert %{"branch" => "default", "goto" => 4} in routes
  end

  test "only touched workflows are listed; a clean one beside them is not" do
    rows = [
      step(1, 5, 1),
      step(2, 5, 1),
      step(3, 6, 1),
      step(4, 6, 2)
    ]

    %{updates: updates, workflows: workflows} = PositionRepair.plan(rows)

    assert workflows == [5]
    refute Enum.any?(updates, &(&1.id in [3, 4]))
  end

  test "the result has no duplicate positions within any workflow" do
    rows = for id <- 1..6, do: step(id, 1, rem(id, 2) + 1)

    %{updates: updates} = PositionRepair.plan(rows)
    positions = Enum.map(updates, & &1.position)

    assert Enum.sort(positions) == Enum.to_list(1..6)
  end
end

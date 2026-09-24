defmodule AlexClaw.Workflows.StepReferencesTest do
  @moduledoc """
  A reference follows its step (reports/WORKFLOW_LIFECYCLE_REVIEW.md, cause 2;
  0.3.55).

  Routes (`goto`) and `input_from` point at step POSITIONS. Reordering or
  removing steps changed the positions and left the references where they
  were: a route to "step 3" silently went to whatever was now third, and a
  run said nothing.

  The rule — positions stay the stored form, so export, import and cloning
  are unchanged:
  - reordering rewrites every `goto` and `input_from`, in the same
    transaction, so each still points at the same step;
  - removing a step shifts the later positions and rewrites the references
    to them the same way;
  - removing a step that a route or `input_from` points to is refused,
    naming the steps that point to it — nothing is rewired to something
    else, and nothing is left dangling;
  - `"end"` and `"default"` are not positions and are left alone.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Workflows

  @api %{"url" => "https://example.com"}

  defp workflow_with(names) do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "Refs #{System.unique_integer([:positive])}",
        enabled: true
      })

    steps =
      for name <- names do
        {:ok, step} = Workflows.add_step(wf, %{name: name, skill: "api_request", config: @api})
        step
      end

    {wf, steps}
  end

  defp step_named(wf, name) do
    {:ok, loaded} = Workflows.get_workflow(wf.id)
    Enum.find(loaded.steps, &(&1.name == name))
  end

  defp position_of(wf, name), do: step_named(wf, name).position

  describe "reordering" do
    test "a route still points at the same step" do
      {wf, [a, b, c]} = workflow_with(~w(A B C))

      {:ok, _} =
        Workflows.update_step(a, %{routes: [%{"branch" => "on_2xx", "goto" => c.position}]})

      {:ok, _} = Workflows.reorder_steps(wf, [c.id, a.id, b.id])

      [route] = step_named(wf, "A").routes
      assert route["goto"] == position_of(wf, "C")
    end

    test "input_from still points at the same step" do
      {wf, [a, b, c]} = workflow_with(~w(A B C))
      {:ok, _} = Workflows.update_step(c, %{input_from: a.position})

      {:ok, _} = Workflows.reorder_steps(wf, [b.id, c.id, a.id])

      assert step_named(wf, "C").input_from == position_of(wf, "A")
    end

    test "end and default are not positions and are left alone" do
      {wf, [a, b]} = workflow_with(~w(A B))

      {:ok, _} =
        Workflows.update_step(a, %{
          routes: [
            %{"branch" => "on_2xx", "goto" => "end"},
            %{"branch" => "default", "goto" => b.position}
          ]
        })

      {:ok, _} = Workflows.reorder_steps(wf, [b.id, a.id])

      routes = step_named(wf, "A").routes
      assert %{"branch" => "on_2xx", "goto" => "end"} in routes
      assert %{"branch" => "default", "goto" => position_of(wf, "B")} in routes
    end
  end

  describe "removing" do
    test "later steps move up, and references to them follow" do
      {wf, [a, b, _c, d]} = workflow_with(~w(A B C D))

      {:ok, _} =
        Workflows.update_step(a, %{routes: [%{"branch" => "on_2xx", "goto" => d.position}]})

      {:ok, _} = Workflows.remove_step(b)

      assert position_of(wf, "D") == 3
      [route] = step_named(wf, "A").routes
      assert route["goto"] == 3
    end

    test "a step something still points to is refused, naming who points to it" do
      {wf, [a, b, c]} = workflow_with(~w(A B C))

      {:ok, _} =
        Workflows.update_step(a, %{routes: [%{"branch" => "on_error", "goto" => c.position}]})

      {:ok, _} = Workflows.update_step(b, %{input_from: c.position})

      assert {:error, reason} = Workflows.remove_step(step_named(wf, "C"))
      assert inspect(reason) =~ "A"
      assert inspect(reason) =~ "B"
      assert step_named(wf, "C"), "the step was removed anyway"
    end

    test "a step nothing points to is removed" do
      {wf, [_a, b]} = workflow_with(~w(A B))
      assert {:ok, _} = Workflows.remove_step(b)
      refute step_named(wf, "B")
    end
  end
end

defmodule AlexClaw.Workflows.WorkflowStepTest do
  use AlexClaw.DataCase, async: true

  alias AlexClaw.Workflows.WorkflowStep

  describe "changeset/2" do
    test "valid with required fields" do
      cs = WorkflowStep.changeset(%WorkflowStep{}, %{
        position: 1,
        name: "Fetch Data",
        skill: "api_request"
      })

      assert cs.valid?
    end

    test "valid with all fields" do
      cs = WorkflowStep.changeset(%WorkflowStep{}, %{
        position: 2,
        name: "Transform",
        skill: "llm_transform",
        llm_tier: "medium",
        llm_model: "gpt-4",
        prompt_template: "Summarize: {input}",
        config: %{"max_tokens" => 500}
      })

      assert cs.valid?
    end

    test "invalid without position" do
      cs = WorkflowStep.changeset(%WorkflowStep{}, %{name: "Step", skill: "api_request"})
      refute cs.valid?
      assert "can't be blank" in errors_on_field(cs, :position)
    end

    test "invalid without name" do
      cs = WorkflowStep.changeset(%WorkflowStep{}, %{position: 1, skill: "api_request"})
      refute cs.valid?
      assert "can't be blank" in errors_on_field(cs, :name)
    end

    test "invalid without skill" do
      cs = WorkflowStep.changeset(%WorkflowStep{}, %{position: 1, name: "Step"})
      refute cs.valid?
      assert "can't be blank" in errors_on_field(cs, :skill)
    end

    test "validates llm_tier inclusion" do
      for tier <- ~w(light medium heavy local) do
        cs = WorkflowStep.changeset(%WorkflowStep{}, %{
          position: 1, name: "S", skill: "s", llm_tier: tier
        })
        assert cs.valid?, "Expected tier '#{tier}' to be valid"
      end
    end

    test "rejects invalid llm_tier" do
      cs = WorkflowStep.changeset(%WorkflowStep{}, %{
        position: 1, name: "S", skill: "s", llm_tier: "superfast"
      })
      refute cs.valid?
      assert errors_on_field(cs, :llm_tier) != []
    end

    test "defaults config to empty map" do
      cs = WorkflowStep.changeset(%WorkflowStep{}, %{position: 1, name: "S", skill: "s"})
      assert Ecto.Changeset.get_field(cs, :config) == %{}
    end
  end

  defp errors_on_field(changeset, field) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Map.get(field, [])
  end
end

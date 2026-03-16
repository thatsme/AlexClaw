defmodule AlexClaw.Workflows.WorkflowResourceTest do
  use AlexClaw.DataCase, async: true

  alias AlexClaw.Workflows.WorkflowResource

  describe "changeset/2" do
    test "valid with required fields" do
      cs = WorkflowResource.changeset(%WorkflowResource{}, %{
        workflow_id: 1,
        resource_id: 1
      })

      assert cs.valid?
    end

    test "valid with role" do
      cs = WorkflowResource.changeset(%WorkflowResource{}, %{
        workflow_id: 1,
        resource_id: 1,
        role: "reference"
      })

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :role) == "reference"
    end

    test "invalid without workflow_id" do
      cs = WorkflowResource.changeset(%WorkflowResource{}, %{resource_id: 1})
      refute cs.valid?
      assert "can't be blank" in errors_on_field(cs, :workflow_id)
    end

    test "invalid without resource_id" do
      cs = WorkflowResource.changeset(%WorkflowResource{}, %{workflow_id: 1})
      refute cs.valid?
      assert "can't be blank" in errors_on_field(cs, :resource_id)
    end

    test "defaults role to input" do
      cs = WorkflowResource.changeset(%WorkflowResource{}, %{
        workflow_id: 1, resource_id: 1
      })
      assert Ecto.Changeset.get_field(cs, :role) == "input"
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

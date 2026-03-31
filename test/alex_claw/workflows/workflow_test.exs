defmodule AlexClaw.Workflows.WorkflowTest do
  use AlexClaw.DataCase, async: true
  @moduletag :integration

  alias AlexClaw.Workflows.Workflow

  describe "changeset/2" do
    test "valid with required fields" do
      cs = Workflow.changeset(%Workflow{}, %{name: "Daily Digest"})
      assert cs.valid?
    end

    test "valid with all fields" do
      cs = Workflow.changeset(%Workflow{}, %{
        name: "Full Workflow",
        description: "A complete workflow",
        enabled: false,
        schedule: "0 7 * * *",
        metadata: %{source: "test"},
        default_provider: "groq"
      })

      assert cs.valid?
    end

    test "invalid without name" do
      cs = Workflow.changeset(%Workflow{}, %{})
      refute cs.valid?
      assert "can't be blank" in errors_on_field(cs, :name)
    end

    test "defaults enabled to true" do
      cs = Workflow.changeset(%Workflow{}, %{name: "Test"})
      assert Ecto.Changeset.get_field(cs, :enabled) == true
    end

    test "defaults metadata to empty map" do
      cs = Workflow.changeset(%Workflow{}, %{name: "Test"})
      assert Ecto.Changeset.get_field(cs, :metadata) == %{}
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

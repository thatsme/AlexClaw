defmodule AlexClaw.Skills.DynamicSkillTest do
  use AlexClaw.DataCase

  alias AlexClaw.Skills.DynamicSkill

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end

  describe "changeset/2" do
    test "valid changeset with all fields" do
      attrs = %{
        name: "test_skill",
        module_name: "Elixir.AlexClaw.Skills.Dynamic.TestSkill",
        file_path: "test_skill.ex",
        permissions: ["llm", "web_read"],
        checksum: "abc123",
        enabled: true
      }

      changeset = DynamicSkill.changeset(%DynamicSkill{}, attrs)
      assert changeset.valid?
    end

    test "requires name, module_name, file_path, checksum" do
      changeset = DynamicSkill.changeset(%DynamicSkill{}, %{})
      refute changeset.valid?

      errors = errors_on(changeset)
      assert "can't be blank" in errors.name
      assert "can't be blank" in errors.module_name
      assert "can't be blank" in errors.file_path
      assert "can't be blank" in errors.checksum
    end

    test "defaults enabled to true" do
      attrs = %{
        name: "test",
        module_name: "Elixir.AlexClaw.Skills.Dynamic.Test",
        file_path: "test.ex",
        checksum: "abc"
      }

      changeset = DynamicSkill.changeset(%DynamicSkill{}, attrs)
      assert Ecto.Changeset.get_field(changeset, :enabled) == true
    end

    test "defaults permissions to empty list" do
      attrs = %{
        name: "test",
        module_name: "Elixir.AlexClaw.Skills.Dynamic.Test",
        file_path: "test.ex",
        checksum: "abc"
      }

      changeset = DynamicSkill.changeset(%DynamicSkill{}, attrs)
      assert Ecto.Changeset.get_field(changeset, :permissions) == []
    end

    test "enforces unique name" do
      attrs = %{
        name: "unique_test",
        module_name: "Elixir.AlexClaw.Skills.Dynamic.UniqueTest",
        file_path: "unique_test.ex",
        permissions: [],
        checksum: "abc",
        enabled: true
      }

      assert {:ok, _} = %DynamicSkill{} |> DynamicSkill.changeset(attrs) |> AlexClaw.Repo.insert()
      assert {:error, changeset} = %DynamicSkill{} |> DynamicSkill.changeset(attrs) |> AlexClaw.Repo.insert()
      assert "has already been taken" in errors_on(changeset).name
    end
  end
end

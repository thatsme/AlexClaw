defmodule AlexClaw.Config.SettingTest do
  use AlexClaw.DataCase, async: true
  @moduletag :integration

  alias AlexClaw.Config.Setting

  describe "changeset/2" do
    test "valid with required fields" do
      cs = Setting.changeset(%Setting{}, %{key: "test.key", value: "hello", type: "string"})
      assert cs.valid?
    end

    test "invalid without key" do
      cs = Setting.changeset(%Setting{}, %{value: "hello", type: "string"})
      refute cs.valid?
      assert %{key: ["can't be blank"]} = errors_on(cs)
    end

    test "valid without value (defaults to empty string)" do
      cs = Setting.changeset(%Setting{}, %{key: "test.key", type: "string"})
      assert cs.valid?
    end

    test "invalid type rejected" do
      cs = Setting.changeset(%Setting{}, %{key: "k", value: "v", type: "xml"})
      refute cs.valid?
      assert %{type: [_]} = errors_on(cs)
    end

    test "valid types accepted" do
      for type <- ~w(string integer float boolean json) do
        cs = Setting.changeset(%Setting{}, %{key: "k", value: "v", type: type})
        assert cs.valid?, "expected type #{type} to be valid"
      end
    end

    test "defaults category to general" do
      cs = Setting.changeset(%Setting{}, %{key: "k", value: "v", type: "string"})
      assert Ecto.Changeset.get_field(cs, :category) == "general"
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end

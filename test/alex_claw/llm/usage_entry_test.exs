defmodule AlexClaw.LLM.UsageEntryTest do
  use AlexClaw.DataCase, async: true
  @moduletag :integration

  alias AlexClaw.LLM.UsageEntry

  describe "changeset/2" do
    test "valid with required fields" do
      cs = UsageEntry.changeset(%UsageEntry{}, %{
        model: "llama-3-8b",
        date: Date.utc_today(),
        count: 5
      })

      assert cs.valid?
    end

    test "invalid without model" do
      cs = UsageEntry.changeset(%UsageEntry{}, %{date: Date.utc_today(), count: 0})
      refute cs.valid?
      assert "can't be blank" in errors_on_field(cs, :model)
    end

    test "invalid without date" do
      cs = UsageEntry.changeset(%UsageEntry{}, %{model: "m", count: 0})
      refute cs.valid?
      assert "can't be blank" in errors_on_field(cs, :date)
    end

    test "count defaults to 0 in changeset" do
      cs = UsageEntry.changeset(%UsageEntry{}, %{model: "m", date: Date.utc_today()})
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :count) == 0
    end

    test "defaults count to 0 on struct" do
      entry = %UsageEntry{}
      assert entry.count == 0
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

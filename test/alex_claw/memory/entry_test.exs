defmodule AlexClaw.Memory.EntryTest do
  use AlexClaw.DataCase, async: true

  alias AlexClaw.Memory.Entry

  describe "changeset/2" do
    test "valid with required fields" do
      cs = Entry.changeset(%Entry{}, %{kind: "test", content: "some text"})
      assert cs.valid?
    end

    test "valid with all fields" do
      cs = Entry.changeset(%Entry{}, %{
        kind: "news",
        content: "headline",
        source: "https://example.com",
        metadata: %{feed: "tech"},
        expires_at: DateTime.utc_now()
      })

      assert cs.valid?
    end

    test "invalid without kind" do
      cs = Entry.changeset(%Entry{}, %{content: "text"})
      refute cs.valid?
      assert "can't be blank" in errors_on_field(cs, :kind)
    end

    test "invalid without content" do
      cs = Entry.changeset(%Entry{}, %{kind: "test"})
      refute cs.valid?
      assert "can't be blank" in errors_on_field(cs, :content)
    end

    test "defaults metadata to empty map" do
      entry = %Entry{}
      assert entry.metadata == %{}
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

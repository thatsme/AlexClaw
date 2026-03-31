defmodule AlexClaw.Resources.ResourceTest do
  use AlexClaw.DataCase, async: true
  @moduletag :integration

  alias AlexClaw.Resources.Resource

  describe "changeset/2" do
    test "valid with required fields" do
      cs = Resource.changeset(%Resource{}, %{name: "My Feed", type: "rss_feed"})
      assert cs.valid?
    end

    test "valid with all fields" do
      cs = Resource.changeset(%Resource{}, %{
        name: "API Source",
        type: "api",
        url: "https://example.com/api",
        content: "some content",
        metadata: %{key: "value"},
        tags: ["financial", "data"],
        enabled: false
      })

      assert cs.valid?
    end

    test "invalid without name" do
      cs = Resource.changeset(%Resource{}, %{type: "rss_feed"})
      refute cs.valid?
      assert "can't be blank" in errors_on_field(cs, :name)
    end

    test "invalid without type" do
      cs = Resource.changeset(%Resource{}, %{name: "Test"})
      refute cs.valid?
      assert "can't be blank" in errors_on_field(cs, :type)
    end

    test "invalid with unknown type" do
      cs = Resource.changeset(%Resource{}, %{name: "Test", type: "unknown"})
      refute cs.valid?
      assert errors_on_field(cs, :type) != []
    end

    test "accepts all allowed types" do
      for type <- ~w(rss_feed website document api) do
        cs = Resource.changeset(%Resource{}, %{name: "Test", type: type})
        assert cs.valid?, "Expected type '#{type}' to be valid"
      end
    end

    test "defaults enabled to true" do
      cs = Resource.changeset(%Resource{}, %{name: "Test", type: "api"})
      assert Ecto.Changeset.get_field(cs, :enabled) == true
    end

    test "defaults metadata to empty map" do
      cs = Resource.changeset(%Resource{}, %{name: "Test", type: "api"})
      assert Ecto.Changeset.get_field(cs, :metadata) == %{}
    end

    test "defaults tags to empty list" do
      cs = Resource.changeset(%Resource{}, %{name: "Test", type: "api"})
      assert Ecto.Changeset.get_field(cs, :tags) == []
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

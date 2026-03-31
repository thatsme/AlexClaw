defmodule AlexClaw.ResourcesTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Resources

  defp create_resource(attrs \\ %{}) do
    default = %{name: "Resource #{System.unique_integer([:positive])}", type: "rss_feed", url: "https://example.com/feed"}
    {:ok, r} = Resources.create_resource(Map.merge(default, attrs))
    r
  end

  describe "create_resource/1" do
    test "creates with valid attrs" do
      {:ok, r} = Resources.create_resource(%{name: "Test Feed", type: "rss_feed", url: "https://example.com"})
      assert r.name == "Test Feed"
      assert r.type == "rss_feed"
      assert r.enabled == true
    end

    test "fails without name" do
      {:error, cs} = Resources.create_resource(%{type: "rss_feed"})
      assert %{name: ["can't be blank"]} = errors_on(cs)
    end
  end

  describe "list_resources/1" do
    test "returns all resources" do
      r = create_resource()
      resources = Resources.list_resources()
      assert Enum.any?(resources, &(&1.id == r.id))
    end

    test "filters by type" do
      create_resource(%{type: "rss_feed"})
      create_resource(%{type: "website"})

      feeds = Resources.list_resources(%{type: "rss_feed"})
      assert Enum.all?(feeds, &(&1.type == "rss_feed"))
    end

    test "filters by enabled" do
      create_resource(%{enabled: true})
      create_resource(%{enabled: false})

      enabled = Resources.list_resources(%{enabled: true})
      assert Enum.all?(enabled, &(&1.enabled == true))
    end
  end

  describe "update_resource/2" do
    test "updates attrs" do
      r = create_resource()
      {:ok, updated} = Resources.update_resource(r, %{name: "Updated Name"})
      assert updated.name == "Updated Name"
    end
  end

  describe "delete_resource/1" do
    test "removes resource" do
      r = create_resource()
      {:ok, _} = Resources.delete_resource(r)
      assert_raise Ecto.NoResultsError, fn -> Resources.get_resource!(r.id) end
    end
  end

  describe "list_by_tags/1" do
    test "finds resources matching tags" do
      create_resource(%{tags: ["financial", "markets"]})
      create_resource(%{tags: ["tech", "ai"]})

      results = Resources.list_by_tags(["financial"])
      assert Enum.all?(results, fn r -> "financial" in r.tags end)
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

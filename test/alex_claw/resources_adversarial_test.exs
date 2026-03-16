defmodule AlexClaw.ResourcesAdversarialTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.Resources

  describe "create_resource/1 edge cases" do
    test "rejects empty name" do
      {:error, cs} = Resources.create_resource(%{name: "", type: "rss_feed"})
      assert cs.valid? == false
    end

    test "rejects invalid type" do
      {:error, cs} = Resources.create_resource(%{name: "Test", type: "invalid_type"})
      assert cs.valid? == false
    end

    test "accepts resource with very long name" do
      long_name = String.duplicate("a", 255)
      {:ok, resource} = Resources.create_resource(%{name: long_name, type: "api"})
      assert resource.name == long_name
    end

    test "accepts resource with unicode name" do
      {:ok, resource} = Resources.create_resource(%{name: "日本語リソース 🎯", type: "website"})
      assert resource.name =~ "日本語"
    end

    test "accepts resource with empty tags" do
      {:ok, resource} = Resources.create_resource(%{name: "Test", type: "api", tags: []})
      assert resource.tags == []
    end

    test "accepts resource with special chars in URL" do
      {:ok, resource} = Resources.create_resource(%{
        name: "Special URL",
        type: "api",
        url: "https://example.com/path?q=hello+world&lang=en#section"
      })

      assert resource.url =~ "hello+world"
    end

    test "handles metadata with special values" do
      {:ok, resource} = Resources.create_resource(%{
        name: "Meta Test",
        type: "document",
        metadata: %{"key" => nil, "nested" => %{"a" => 1}, "list" => [1, 2]}
      })

      assert resource.metadata["nested"]["a"] == 1
    end
  end

  describe "update_resource/2 edge cases" do
    test "update to invalid type fails" do
      {:ok, resource} = Resources.create_resource(%{name: "Valid", type: "api"})
      {:error, cs} = Resources.update_resource(resource, %{type: "not_valid"})
      assert cs.valid? == false
    end

    test "update name to empty fails" do
      {:ok, resource} = Resources.create_resource(%{name: "Valid", type: "api"})
      {:error, cs} = Resources.update_resource(resource, %{name: ""})
      assert cs.valid? == false
    end
  end

  describe "list_resources/1 filtering" do
    test "filter by type returns only matching" do
      {:ok, _} = Resources.create_resource(%{name: "RSS #{System.unique_integer([:positive])}", type: "rss_feed"})
      {:ok, _} = Resources.create_resource(%{name: "API #{System.unique_integer([:positive])}", type: "api"})

      rss_only = Resources.list_resources(%{type: "rss_feed"})
      assert Enum.all?(rss_only, &(&1.type == "rss_feed"))
    end

    test "filter by nonexistent type returns empty" do
      result = Resources.list_resources(%{type: "nonexistent"})
      assert result == []
    end

    test "filter by enabled returns only enabled" do
      {:ok, _} = Resources.create_resource(%{name: "Enabled #{System.unique_integer([:positive])}", type: "api", enabled: true})
      {:ok, _} = Resources.create_resource(%{name: "Disabled #{System.unique_integer([:positive])}", type: "api", enabled: false})

      enabled_only = Resources.list_resources(%{enabled: true})
      assert Enum.all?(enabled_only, & &1.enabled)
    end
  end

  describe "delete_resource/1" do
    test "delete then get raises" do
      {:ok, resource} = Resources.create_resource(%{name: "Temp", type: "api"})
      {:ok, _} = Resources.delete_resource(resource)

      assert_raise Ecto.NoResultsError, fn ->
        Resources.get_resource!(resource.id)
      end
    end
  end
end

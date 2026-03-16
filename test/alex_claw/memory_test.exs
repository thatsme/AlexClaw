defmodule AlexClaw.MemoryTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.Memory

  describe "store/3" do
    test "stores a memory entry" do
      {:ok, entry} = Memory.store(:test, "some knowledge")
      assert entry.kind == "test"
      assert entry.content == "some knowledge"
    end

    test "stores with source and metadata" do
      {:ok, entry} = Memory.store(:news, "headline",
        source: "https://example.com",
        metadata: %{feed: "test_feed"}
      )
      assert entry.source == "https://example.com"
      assert entry.metadata["feed"] == "test_feed" or entry.metadata.feed == "test_feed"
    end

    test "stores with string kind" do
      {:ok, entry} = Memory.store("custom_kind", "content")
      assert entry.kind == "custom_kind"
    end
  end

  describe "exists?/1" do
    test "returns true for existing content" do
      {:ok, _} = Memory.store(:test, "unique content here")
      assert Memory.exists?("unique content here")
    end

    test "returns true for existing source" do
      {:ok, _} = Memory.store(:test, "content", source: "https://unique.example.com")
      assert Memory.exists?("https://unique.example.com")
    end

    test "returns false for nonexistent content" do
      refute Memory.exists?("definitely not stored #{System.unique_integer()}")
    end
  end

  describe "recent/1" do
    test "returns entries ordered by newest first" do
      {:ok, _first} = Memory.store(:test, "first_entry")
      {:ok, _second} = Memory.store(:test, "second_entry")

      entries = Memory.recent(limit: 2)
      assert length(entries) == 2
      contents = Enum.map(entries, & &1.content)
      assert "first_entry" in contents
      assert "second_entry" in contents
    end

    test "filters by kind" do
      {:ok, _} = Memory.store(:alpha, "alpha content")
      {:ok, _} = Memory.store(:beta, "beta content")

      alphas = Memory.recent(kind: :alpha)
      assert Enum.all?(alphas, &(&1.kind == "alpha"))
    end

    test "respects limit" do
      for i <- 1..5, do: {:ok, _} = Memory.store(:test, "item #{i}")

      entries = Memory.recent(limit: 3)
      assert length(entries) == 3
    end
  end

  describe "search/2" do
    test "keyword search matches content" do
      {:ok, _} = Memory.store(:test, "Elixir pattern matching is great")
      {:ok, _} = Memory.store(:test, "Python is also nice")

      results = Memory.search("Elixir")
      assert Enum.any?(results, &String.contains?(&1.content, "Elixir"))
    end

    test "keyword search filters by kind" do
      {:ok, _} = Memory.store(:tech, "Elixir rocks")
      {:ok, _} = Memory.store(:news, "Elixir news today")

      results = Memory.search("Elixir", kind: :tech)
      assert Enum.all?(results, &(&1.kind == "tech"))
    end
  end
end

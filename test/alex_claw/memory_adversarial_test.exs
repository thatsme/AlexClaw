defmodule AlexClaw.MemoryAdversarialTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.Memory

  describe "store/3 edge cases" do
    test "stores very long content" do
      long_text = String.duplicate("x", 100_000)
      {:ok, entry} = Memory.store(:test, long_text)
      assert String.length(entry.content) == 100_000
    end

    test "stores content with unicode" do
      {:ok, entry} = Memory.store(:test, "日本語テスト 🚀 émojis")
      assert entry.content =~ "日本語"
    end

    test "null bytes in content cause Postgres error — known limitation" do
      content = "before\0after"
      assert_raise Postgrex.Error, fn ->
        Memory.store(:test, content)
      end
    end

    test "stores content with newlines and special chars" do
      {:ok, entry} = Memory.store(:test, "line1\nline2\ttab\r\nCRLF")
      assert entry.content =~ "line1\nline2"
    end

    test "stores with empty metadata" do
      {:ok, entry} = Memory.store(:test, "content", metadata: %{})
      assert entry.metadata == %{}
    end

    test "stores with deeply nested metadata" do
      meta = %{a: %{b: %{c: %{d: [1, 2, 3]}}}}
      {:ok, entry} = Memory.store(:test, "content", metadata: meta)
      assert entry.metadata != %{}
    end

    test "atom kind gets converted to string" do
      {:ok, entry} = Memory.store(:my_custom_kind, "content")
      assert entry.kind == "my_custom_kind"
    end
  end

  describe "search/2 edge cases" do
    test "empty search returns results (no filter applied)" do
      {:ok, _} = Memory.store(:test, "searchable content")
      results = Memory.search("")
      assert is_list(results)
    end

    test "search with special regex chars doesn't crash" do
      results = Memory.search("(.*)")
      assert is_list(results)
    end

    test "search with SQL injection attempt" do
      results = Memory.search("'; DROP TABLE memories; --")
      assert is_list(results)
    end

    test "search with very long query" do
      long_query = String.duplicate("search ", 1000)
      results = Memory.search(long_query)
      assert is_list(results)
    end
  end

  describe "exists?/1 edge cases" do
    test "empty string returns false" do
      refute Memory.exists?("")
    end

    test "SQL injection in exists? check" do
      refute Memory.exists?("' OR 1=1; --")
    end

    test "very long string in exists?" do
      long = String.duplicate("x", 100_000)
      refute Memory.exists?(long)
    end
  end

  describe "recent/1 edge cases" do
    test "limit of 0 returns empty list" do
      {:ok, _} = Memory.store(:test, "something")
      assert Memory.recent(limit: 0) == []
    end

    test "very large limit doesn't crash" do
      results = Memory.recent(limit: 1_000_000)
      assert is_list(results)
    end

    test "filter by nonexistent kind returns empty" do
      assert Memory.recent(kind: :definitely_not_a_kind) == []
    end
  end
end

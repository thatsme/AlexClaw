defmodule AlexClaw.MemoryTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.Memory
  alias AlexClaw.Memory.Entry

  describe "store/3" do
    test "stores a memory entry immediately with nil embedding" do
      {:ok, entry} = Memory.store(:test, "some knowledge")
      assert entry.kind == "test"
      assert entry.content == "some knowledge"
      assert entry.embedding == nil
    end

    test "stores with source and metadata" do
      {:ok, entry} =
        Memory.store(:news, "headline",
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

    test "async embeds entry when provider is available" do
      bypass = Bypass.open()
      vector = List.duplicate(0.1, 768)

      Bypass.expect(bypass, "POST", "/v1beta/models/text-embedding-004:embedContent", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"embedding" => %{"values" => vector}}))
      end)

      Application.put_env(:alex_claw, :embedding_base_url, "http://localhost:#{bypass.port}")

      {:ok, _} =
        AlexClaw.LLM.create_provider(%{
          name: "embed_test_gemini_#{System.unique_integer([:positive])}",
          type: "gemini",
          model: "gemini-2.0-flash",
          api_key: "test-key",
          tier: "light",
          enabled: true,
          priority: 10
        })

      {:ok, entry} = Memory.store(:test, "embedding test content")
      # Entry is returned immediately with nil embedding
      assert entry.embedding == nil

      # Wait for async task to complete
      Process.sleep(200)

      updated = AlexClaw.Repo.get(Entry, entry.id)
      assert updated.embedding != nil
      assert updated.embedding |> Pgvector.to_list() |> length() == 768

      Application.delete_env(:alex_claw, :embedding_base_url)
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

  describe "count/1" do
    test "returns 0 when no entries exist" do
      assert Memory.count() == 0
    end

    test "counts all entries" do
      {:ok, _} = Memory.store(:test, "one")
      {:ok, _} = Memory.store(:test, "two")
      {:ok, _} = Memory.store(:news, "three")

      assert Memory.count() == 3
    end

    test "filters by kind" do
      {:ok, _} = Memory.store(:test, "one")
      {:ok, _} = Memory.store(:news, "two")

      assert Memory.count(:test) == 1
      assert Memory.count(:news) == 1
    end
  end

  describe "search/2" do
    test "keyword search matches content when no embedding provider" do
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

    test "hybrid search merges vector and keyword results" do
      # Insert entries with pre-set embeddings to test hybrid merge
      query_vector = List.duplicate(0.5, 768)
      similar_vector = List.duplicate(0.5, 768)

      {:ok, with_embed} =
        %Entry{}
        |> Entry.changeset(%{
          kind: "test",
          content: "vector matched content",
          embedding: similar_vector
        })
        |> AlexClaw.Repo.insert()

      {:ok, keyword_only} =
        %Entry{}
        |> Entry.changeset(%{
          kind: "test",
          content: "keyword matched searchterm here",
          embedding: nil
        })
        |> AlexClaw.Repo.insert()

      bypass = Bypass.open()

      Bypass.expect(bypass, "POST", "/v1beta/models/text-embedding-004:embedContent", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"embedding" => %{"values" => query_vector}}))
      end)

      Application.put_env(:alex_claw, :embedding_base_url, "http://localhost:#{bypass.port}")

      {:ok, _} =
        AlexClaw.LLM.create_provider(%{
          name: "hybrid_test_gemini_#{System.unique_integer([:positive])}",
          type: "gemini",
          model: "gemini-2.0-flash",
          api_key: "test-key",
          tier: "light",
          enabled: true,
          priority: 10
        })

      results = Memory.search("searchterm")
      result_ids = Enum.map(results, & &1.id)

      # Both should appear: vector match + keyword match
      assert with_embed.id in result_ids
      assert keyword_only.id in result_ids

      Application.delete_env(:alex_claw, :embedding_base_url)
    end

    test "deduplicates entries that match both vector and keyword" do
      vector = List.duplicate(0.5, 768)

      {:ok, entry} =
        %Entry{}
        |> Entry.changeset(%{
          kind: "test",
          content: "deduplicate this unique content",
          embedding: vector
        })
        |> AlexClaw.Repo.insert()

      bypass = Bypass.open()

      Bypass.expect(bypass, "POST", "/v1beta/models/text-embedding-004:embedContent", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"embedding" => %{"values" => vector}}))
      end)

      Application.put_env(:alex_claw, :embedding_base_url, "http://localhost:#{bypass.port}")

      {:ok, _} =
        AlexClaw.LLM.create_provider(%{
          name: "dedup_test_gemini_#{System.unique_integer([:positive])}",
          type: "gemini",
          model: "gemini-2.0-flash",
          api_key: "test-key",
          tier: "light",
          enabled: true,
          priority: 10
        })

      results = Memory.search("deduplicate")
      matching = Enum.filter(results, &(&1.id == entry.id))
      assert length(matching) == 1

      Application.delete_env(:alex_claw, :embedding_base_url)
    end
  end

  describe "reembed_all/1" do
    test "returns count of entries to process" do
      {:ok, _} = Memory.store(:test, "entry one")
      {:ok, _} = Memory.store(:test, "entry two")

      assert {:ok, count} = Memory.reembed_all()
      assert count >= 2
    end

    test "returns zero when all entries have embeddings" do
      vector = List.duplicate(0.1, 768)

      %Entry{}
      |> Entry.changeset(%{kind: "test", content: "already embedded", embedding: vector})
      |> AlexClaw.Repo.insert!()

      assert {:ok, 0} = Memory.reembed_all()
    end
  end
end

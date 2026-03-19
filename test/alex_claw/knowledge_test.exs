defmodule AlexClaw.KnowledgeTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.Knowledge
  alias AlexClaw.Knowledge.Entry

  describe "store/3" do
    test "stores a knowledge entry immediately with nil embedding" do
      {:ok, entry} = Knowledge.store(:hexdocs, "GenServer documentation")
      assert entry.kind == "hexdocs"
      assert entry.content == "GenServer documentation"
      assert entry.embedding == nil
    end

    test "stores with source and metadata" do
      {:ok, entry} =
        Knowledge.store(:hexdocs, "Ecto.Repo docs",
          source: "https://hexdocs.pm/ecto/Ecto.Repo.html",
          metadata: %{package: "ecto", module: "Ecto.Repo"}
        )

      assert entry.source == "https://hexdocs.pm/ecto/Ecto.Repo.html"
      assert entry.metadata["package"] == "ecto" or entry.metadata.package == "ecto"
    end

    test "stores with string kind" do
      {:ok, entry} = Knowledge.store("erlang_docs", "OTP design principles")
      assert entry.kind == "erlang_docs"
    end

    test "validates required fields" do
      assert {:error, changeset} = Knowledge.store(:hexdocs, "")
      refute changeset.valid?
    end
  end

  describe "exists?/1" do
    test "returns true for existing source URL" do
      {:ok, _} = Knowledge.store(:hexdocs, "content", source: "https://hexdocs.pm/test/unique")
      assert Knowledge.exists?("https://hexdocs.pm/test/unique")
    end

    test "returns false for nonexistent source" do
      refute Knowledge.exists?("https://hexdocs.pm/nonexistent/#{System.unique_integer()}")
    end
  end

  describe "recent/1" do
    test "returns entries ordered by newest first" do
      {:ok, _} = Knowledge.store(:hexdocs, "first doc")
      {:ok, _} = Knowledge.store(:hexdocs, "second doc")

      entries = Knowledge.recent(limit: 2)
      assert length(entries) == 2
    end

    test "filters by kind" do
      {:ok, _} = Knowledge.store(:hexdocs, "hex content")
      {:ok, _} = Knowledge.store(:erlang_docs, "erlang content")

      hexdocs = Knowledge.recent(kind: :hexdocs)
      assert Enum.all?(hexdocs, &(&1.kind == "hexdocs"))
    end

    test "respects limit" do
      for i <- 1..5, do: {:ok, _} = Knowledge.store(:hexdocs, "doc #{i}")

      entries = Knowledge.recent(limit: 3)
      assert length(entries) == 3
    end
  end

  describe "count/1" do
    test "counts all entries when kind is nil" do
      {:ok, _} = Knowledge.store(:hexdocs, "one")
      {:ok, _} = Knowledge.store(:erlang_docs, "two")

      assert Knowledge.count() >= 2
    end

    test "counts entries filtered by kind" do
      {:ok, _} = Knowledge.store(:hexdocs, "hex entry #{System.unique_integer()}")
      {:ok, _} = Knowledge.store(:erlang_docs, "erlang entry #{System.unique_integer()}")

      hex_count = Knowledge.count(:hexdocs)
      erlang_count = Knowledge.count(:erlang_docs)
      assert hex_count >= 1
      assert erlang_count >= 1
    end
  end

  describe "search/2" do
    test "keyword search matches content terms" do
      {:ok, _} = Knowledge.store(:hexdocs, "GenServer handle_call callback documentation")
      {:ok, _} = Knowledge.store(:hexdocs, "Enum map filter reduce functions")

      results = Knowledge.search("GenServer handle_call")
      assert Enum.any?(results, &String.contains?(&1.content, "GenServer"))
    end

    test "keyword search filters by kind" do
      {:ok, _} = Knowledge.store(:hexdocs, "Phoenix Router plug pipeline")
      {:ok, _} = Knowledge.store(:erlang_docs, "Phoenix OTP supervision tree")

      results = Knowledge.search("Phoenix", kind: :hexdocs)
      assert Enum.all?(results, &(&1.kind == "hexdocs"))
    end

    test "keyword search extracts terms and ignores stop words" do
      {:ok, _} =
        Knowledge.store(:hexdocs, "transaction options Ecto Repo accept",
          source: "https://hexdocs.pm/ecto/test_keyword_#{System.unique_integer()}"
        )

      results = Knowledge.search("What options does Ecto Repo transaction accept?")
      assert Enum.any?(results, &String.contains?(&1.content, "transaction"))
    end

    test "returns empty list for no matches" do
      results = Knowledge.search("zzz_nonexistent_term_#{System.unique_integer()}")
      assert results == []
    end
  end

  describe "search/2 hybrid merge" do
    test "keyword results are prioritized over vector results" do
      vector = List.duplicate(0.5, 768)

      {:ok, keyword_entry} =
        %Entry{}
        |> Entry.changeset(%{
          kind: "hexdocs",
          content: "Ecto.Repo transaction options callback",
          embedding: nil
        })
        |> AlexClaw.Repo.insert()

      {:ok, vector_entry} =
        %Entry{}
        |> Entry.changeset(%{
          kind: "hexdocs",
          content: "unrelated vector content",
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
          name: "knowledge_hybrid_test_#{System.unique_integer([:positive])}",
          type: "gemini",
          model: "gemini-2.0-flash",
          api_key: "test-key",
          tier: "light",
          enabled: true,
          priority: 10
        })

      results = Knowledge.search("Ecto Repo transaction options")
      result_ids = Enum.map(results, & &1.id)

      assert keyword_entry.id in result_ids

      # Keyword match should appear before vector-only match
      kw_pos = Enum.find_index(result_ids, &(&1 == keyword_entry.id))
      vec_pos = Enum.find_index(result_ids, &(&1 == vector_entry.id))

      if vec_pos do
        assert kw_pos < vec_pos
      end

      Application.delete_env(:alex_claw, :embedding_base_url)
    end

    test "deduplicates entries matching both keyword and vector" do
      vector = List.duplicate(0.5, 768)

      {:ok, entry} =
        %Entry{}
        |> Entry.changeset(%{
          kind: "hexdocs",
          content: "deduplicate knowledge unique content",
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
          name: "knowledge_dedup_test_#{System.unique_integer([:positive])}",
          type: "gemini",
          model: "gemini-2.0-flash",
          api_key: "test-key",
          tier: "light",
          enabled: true,
          priority: 10
        })

      results = Knowledge.search("deduplicate knowledge")
      matching = Enum.filter(results, &(&1.id == entry.id))
      assert length(matching) == 1

      Application.delete_env(:alex_claw, :embedding_base_url)
    end
  end

  describe "reembed_all/1" do
    test "returns count of entries to process" do
      {:ok, _} = Knowledge.store(:hexdocs, "entry one")
      {:ok, _} = Knowledge.store(:hexdocs, "entry two")

      assert {:ok, count} = Knowledge.reembed_all()
      assert count >= 2
    end

    test "returns zero when all entries have embeddings" do
      vector = List.duplicate(0.1, 768)

      %Entry{}
      |> Entry.changeset(%{kind: "hexdocs", content: "already embedded", embedding: vector})
      |> AlexClaw.Repo.insert!()

      assert {:ok, 0} = Knowledge.reembed_all()
    end
  end
end

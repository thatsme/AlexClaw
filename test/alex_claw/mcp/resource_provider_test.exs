defmodule AlexClaw.MCP.ResourceProviderTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.MCP.ResourceProvider
  alias Anubis.Server.{Frame, Response}

  defp new_frame, do: Frame.new()

  describe "register_templates/1" do
    test "registers all 6 resource templates" do
      frame = ResourceProvider.register_templates(new_frame())

      assert map_size(frame.resource_templates) == 6

      names = Map.keys(frame.resource_templates)
      assert "resources" in names
      assert "knowledge" in names
      assert "memory" in names
      assert "workflows" in names
      assert "runs" in names
      assert "config" in names
    end
  end

  describe "read alexclaw://resources/" do
    test "list returns all resources" do
      AlexClaw.Resources.create_resource(%{
        name: "Test Feed",
        type: "rss_feed",
        url: "https://example.com/feed.xml",
        tags: ["test"]
      })

      {:reply, %Response{} = resp, _frame} =
        ResourceProvider.read("alexclaw://resources/list", new_frame())

      data = decode_response(resp)
      assert is_list(data)
      assert Enum.any?(data, &(&1["name"] == "Test Feed"))
    end

    test "get by ID returns specific resource" do
      {:ok, resource} =
        AlexClaw.Resources.create_resource(%{
          name: "Get Test",
          type: "website",
          url: "https://example.com"
        })

      {:reply, %Response{} = resp, _frame} =
        ResourceProvider.read("alexclaw://resources/#{resource.id}", new_frame())

      data = decode_response(resp)
      assert data["id"] == resource.id
      assert data["name"] == "Get Test"
    end

    test "returns error for non-existent resource" do
      {:error, _error, _frame} =
        ResourceProvider.read("alexclaw://resources/999999", new_frame())
    end

    test "returns error for invalid ID" do
      {:error, _error, _frame} =
        ResourceProvider.read("alexclaw://resources/abc", new_frame())
    end
  end

  describe "read alexclaw://knowledge/" do
    test "list returns recent knowledge entries" do
      AlexClaw.Knowledge.store(:documentation, "Test knowledge content",
        source: "test://knowledge-test"
      )

      {:reply, %Response{} = resp, _frame} =
        ResourceProvider.read("alexclaw://knowledge/list", new_frame())

      data = decode_response(resp)
      assert is_list(data)
      assert Enum.any?(data, &(&1["content"] == "Test knowledge content"))
    end

    test "search returns matching entries" do
      AlexClaw.Knowledge.store(:documentation, "Elixir GenServer patterns",
        source: "test://knowledge-search"
      )

      {:reply, %Response{} = resp, _frame} =
        ResourceProvider.read("alexclaw://knowledge/search:GenServer", new_frame())

      data = decode_response(resp)
      assert is_list(data)
    end

    test "returns error for non-existent entry" do
      {:error, _error, _frame} =
        ResourceProvider.read("alexclaw://knowledge/999999", new_frame())
    end
  end

  describe "read alexclaw://memory/" do
    test "list returns recent memory entries" do
      AlexClaw.Memory.store(:fact, "Test memory fact", source: "test://memory-test")

      {:reply, %Response{} = resp, _frame} =
        ResourceProvider.read("alexclaw://memory/list", new_frame())

      data = decode_response(resp)
      assert is_list(data)
      assert Enum.any?(data, &(&1["content"] == "Test memory fact"))
    end

    test "search returns matching entries" do
      AlexClaw.Memory.store(:fact, "BEAM concurrency model", source: "test://memory-search")

      {:reply, %Response{} = resp, _frame} =
        ResourceProvider.read("alexclaw://memory/search:BEAM", new_frame())

      data = decode_response(resp)
      assert is_list(data)
    end

    test "returns error for non-existent entry" do
      {:error, _error, _frame} =
        ResourceProvider.read("alexclaw://memory/999999", new_frame())
    end
  end

  describe "read alexclaw://workflows/" do
    test "list returns all workflows" do
      {:reply, %Response{} = resp, _frame} =
        ResourceProvider.read("alexclaw://workflows/list", new_frame())

      data = decode_response(resp)
      assert is_list(data)

      for wf <- data do
        assert Map.has_key?(wf, "id")
        assert Map.has_key?(wf, "name")
        assert Map.has_key?(wf, "enabled")
      end
    end

    test "get by ID returns workflow with steps" do
      workflows = AlexClaw.Workflows.list_workflows()

      if length(workflows) > 0 do
        wf = hd(workflows)

        {:reply, %Response{} = resp, _frame} =
          ResourceProvider.read("alexclaw://workflows/#{wf.id}", new_frame())

        data = decode_response(resp)
        assert data["id"] == wf.id
        assert Map.has_key?(data, "steps")
        assert is_list(data["steps"])
      end
    end

    test "returns error for non-existent workflow" do
      {:error, _error, _frame} =
        ResourceProvider.read("alexclaw://workflows/999999", new_frame())
    end
  end

  describe "read alexclaw://runs/" do
    test "list returns recent runs" do
      {:reply, %Response{} = resp, _frame} =
        ResourceProvider.read("alexclaw://runs/list", new_frame())

      data = decode_response(resp)
      assert is_list(data)
    end

    test "returns error for non-existent run" do
      {:error, _error, _frame} =
        ResourceProvider.read("alexclaw://runs/999999", new_frame())
    end
  end

  describe "read alexclaw://config/" do
    test "list returns all settings" do
      {:reply, %Response{} = resp, _frame} =
        ResourceProvider.read("alexclaw://config/list", new_frame())

      data = decode_response(resp)
      assert is_list(data)

      for setting <- data do
        assert Map.has_key?(setting, "key")
        assert Map.has_key?(setting, "value")
      end
    end

    test "sensitive values are redacted" do
      AlexClaw.Config.set("test.secret", "super_secret",
        type: "string",
        category: "test",
        sensitive: true
      )

      {:reply, %Response{} = resp, _frame} =
        ResourceProvider.read("alexclaw://config/list", new_frame())

      data = decode_response(resp)
      secret = Enum.find(data, &(&1["key"] == "test.secret"))

      if secret do
        assert secret["value"] == "[REDACTED]"
      end
    end

    test "get by key returns specific setting" do
      AlexClaw.Config.set("test.mcp.key", "test_value", type: "string", category: "test")

      {:reply, %Response{} = resp, _frame} =
        ResourceProvider.read("alexclaw://config/test.mcp.key", new_frame())

      data = decode_response(resp)
      assert data["key"] == "test.mcp.key"
      assert data["value"] == "test_value"
    end

    test "returns error for non-existent key" do
      {:error, _error, _frame} =
        ResourceProvider.read("alexclaw://config/nonexistent.key.xyz", new_frame())
    end
  end

  describe "unknown URI" do
    test "returns error for unrecognized scheme" do
      {:error, _error, _frame} =
        ResourceProvider.read("unknown://something/123", new_frame())
    end
  end

  defp decode_response(%Response{} = resp) do
    # Response stores content as list of maps with "type" => "text", "text" => json_string
    # For resource responses, content is stored in `contents` field
    text = resp.contents["text"]
    Jason.decode!(text)
  end
end

defmodule AlexClaw.Skills.ConversationalTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :adversarial

  alias AlexClaw.Skills.Conversational
  alias AlexClaw.LLM

  defp create_test_provider(attrs) do
    defaults = %{
      name: "test_conv_#{System.unique_integer([:positive])}",
      type: "openai_compatible",
      host: "http://localhost:9999",
      model: "test-model",
      tier: "light",
      enabled: true,
      priority: 50
    }

    {:ok, provider} = LLM.create_provider(Map.merge(defaults, attrs))
    provider
  end

  defp setup_llm_bypass do
    bypass = Bypass.open()

    create_test_provider(%{
      name: "test_conv_provider",
      type: "openai_compatible",
      host: "http://localhost:#{bypass.port}",
      model: "test-model",
      tier: "light"
    })

    bypass
  end

  defp mock_llm_success(bypass, response_text) do
    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{
        "choices" => [%{"message" => %{"content" => response_text}}]
      }))
    end)
  end

  defp mock_llm_error(bypass, status \\ 500) do
    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(%{"error" => "internal server error"}))
    end)
  end

  describe "run/1 happy path" do
    test "returns success with LLM response" do
      bypass = setup_llm_bypass()
      mock_llm_success(bypass, "Hello from LLM!")

      assert {:ok, "Hello from LLM!", :on_success} = Conversational.run(%{input: "Hi there"})
    end

    test "reads input from config.message when input is nil" do
      bypass = setup_llm_bypass()
      mock_llm_success(bypass, "Config message response")

      assert {:ok, "Config message response", :on_success} =
               Conversational.run(%{input: nil, config: %{"message" => "Hello from config"}})
    end
  end

  describe "run/1 adversarial inputs" do
    test "handles nil input" do
      bypass = setup_llm_bypass()
      mock_llm_success(bypass, "Response to empty")

      assert {:ok, _, :on_success} = Conversational.run(%{input: nil})
    end

    test "handles empty string input" do
      bypass = setup_llm_bypass()
      mock_llm_success(bypass, "Response to empty")

      assert {:ok, _, :on_success} = Conversational.run(%{input: ""})
    end

    test "handles empty args map" do
      bypass = setup_llm_bypass()
      mock_llm_success(bypass, "Response")

      assert {:ok, _, :on_success} = Conversational.run(%{})
    end

    test "handles integer input by converting to string" do
      bypass = setup_llm_bypass()
      mock_llm_success(bypass, "Got number")

      assert {:ok, _, :on_success} = Conversational.run(%{input: 42})
    end
  end

  describe "run/1 LLM failure" do
    test "returns error when LLM returns 500" do
      bypass = setup_llm_bypass()
      mock_llm_error(bypass, 500)

      assert {:error, _reason} = Conversational.run(%{input: "Hello"})
    end

    test "returns error when no LLM provider exists" do
      # Don't create any provider
      assert {:error, _reason} = Conversational.run(%{input: "Hello"})
    end
  end

  describe "run/1 with missing config" do
    test "returns error when no provider matches the tier" do
      # No provider created — tier resolution finds nothing
      AlexClaw.Config.set("skill.conversational.tier", "heavy", type: "string", category: "skill.conversational")

      assert {:error, _reason} = Conversational.run(%{input: "Hello"})
    end

    test "works when skill.conversational.provider is auto" do
      bypass = setup_llm_bypass()
      mock_llm_success(bypass, "Auto provider response")

      AlexClaw.Config.set("skill.conversational.provider", "auto", type: "string", category: "skill.conversational")

      assert {:ok, _, :on_success} = Conversational.run(%{input: "Hello"})
    end
  end

  describe "description/0 and routes/0" do
    test "description is a non-empty string" do
      assert is_binary(Conversational.description())
      assert Conversational.description() != ""
    end

    test "routes include on_success and on_error" do
      assert :on_success in Conversational.routes()
      assert :on_error in Conversational.routes()
    end
  end

  describe "step_fields/0 and config helpers" do
    test "step_fields returns expected atoms" do
      fields = Conversational.step_fields()
      assert :llm_tier in fields
      assert :llm_model in fields
    end

    test "config_scaffold returns map with message key" do
      scaffold = Conversational.config_scaffold()
      assert is_map(scaffold)
      assert Map.has_key?(scaffold, "message")
    end

    test "config_hint returns valid JSON hint" do
      hint = Conversational.config_hint()
      assert {:ok, _} = Jason.decode(hint)
    end
  end
end

defmodule AlexClaw.LLM.ThinkingOptionTest do
  @moduledoc """
  A call can ask a thinking model to answer directly (`thinking: false`), as
  callers needing a strict format do — Forge's code block, llm_score's numbers.
  With thinking on, qwen3 answered Forge in prose and never produced code.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.LLM

  defp provider(type, bypass, options \\ %{}) do
    {:ok, _} =
      LLM.create_provider(%{
        name: "thinking-#{type}",
        type: type,
        tier: "local",
        model: "m",
        host: "http://localhost:#{bypass.port}",
        enabled: true,
        priority: 1,
        options: options
      })
  end

  defp capture(bypass, path, reply) do
    test = self()

    Bypass.expect(bypass, "POST", path, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:body, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(reply))
    end)
  end

  @openai_reply %{"choices" => [%{"message" => %{"content" => "ok"}}]}
  @ollama_reply %{"message" => %{"content" => "ok"}}

  test "OpenAI-compatible: the call's thinking: false becomes enable_thinking false" do
    bypass = Bypass.open()
    provider("openai_compatible", bypass)
    capture(bypass, "/v1/chat/completions", @openai_reply)

    assert {:ok, "ok"} = LLM.complete("hi", tier: :local, thinking: false)
    assert_received {:body, %{"chat_template_kwargs" => %{"enable_thinking" => false}}}
  end

  test "Ollama: it becomes the top-level think field, not a model option" do
    bypass = Bypass.open()
    provider("ollama", bypass, %{"temperature" => 0.3})
    capture(bypass, "/api/chat", @ollama_reply)

    assert {:ok, "ok"} = LLM.complete("hi", tier: :local, thinking: false)
    assert_received {:body, body}
    assert body["think"] == false
    assert body["options"] == %{"temperature" => 0.3}
  end

  test "a call that does not ask leaves the provider's setting alone" do
    bypass = Bypass.open()
    provider("openai_compatible", bypass)
    capture(bypass, "/v1/chat/completions", @openai_reply)

    assert {:ok, "ok"} = LLM.complete("hi", tier: :local)
    assert_received {:body, body}
    refute Map.has_key?(body, "chat_template_kwargs")
  end
end

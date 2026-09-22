defmodule AlexClaw.LLM.RouterFallbackTest do
  @moduledoc """
  A provider that fails hands the call to the next candidate, and the local
  tier is the last resort. Before this, the first provider's error was the
  answer: LM Studio with no model loaded failed every call while Ollama sat
  idle.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.LLM

  defp provider(name, tier, priority, bypass) do
    {:ok, p} =
      LLM.create_provider(%{
        name: name,
        type: "openai_compatible",
        tier: tier,
        model: "m",
        host: "http://localhost:#{bypass.port}",
        enabled: true,
        priority: priority
      })

    p
  end

  defp answers(bypass, status, content) do
    Bypass.stub(bypass, "POST", "/v1/chat/completions", fn conn ->
      body =
        if status == 200,
          do: %{"choices" => [%{"message" => %{"content" => content}}]},
          else: %{"error" => %{"message" => content}}

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end)
  end

  setup do
    %{first: Bypass.open(), second: Bypass.open()}
  end

  test "a failing provider hands over to the next in the tier", %{first: first, second: second} do
    provider("first", "light", 1, first)
    provider("second", "light", 2, second)
    answers(first, 400, "No models loaded")
    answers(second, 200, "from second")

    assert LLM.complete("hi", tier: :light) == {:ok, "from second"}
  end

  test "a tier with no answer falls back to the local tier", %{first: first, second: second} do
    provider("light-one", "light", 1, first)
    provider("local-one", "local", 1, second)
    answers(first, 500, "down")
    answers(second, 200, "from local")

    assert LLM.complete("hi", tier: :light) == {:ok, "from local"}
  end

  test "when every candidate fails, the last failure is the answer", %{
    first: first,
    second: second
  } do
    provider("first", "light", 1, first)
    provider("second", "light", 2, second)
    answers(first, 400, "first failed")
    answers(second, 503, "second failed")

    assert {:error, reason} = LLM.complete("hi", tier: :light)
    assert inspect(reason) =~ "second failed"
  end

  test "a provider asked for by name is the only one tried", %{first: first, second: second} do
    provider("named", "light", 1, first)
    provider("other", "light", 2, second)
    answers(first, 400, "named failed")
    answers(second, 200, "must not be used")

    assert {:error, reason} = LLM.complete("hi", provider: "named")
    assert inspect(reason) =~ "named failed"
  end

  test "with no provider at all, there is no model", %{} do
    assert LLM.complete("hi", tier: :light) == {:error, :no_available_model}
  end
end

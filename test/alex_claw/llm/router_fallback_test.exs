defmodule AlexClaw.LLM.RouterFallbackTest do
  @moduledoc """
  Only a transient failure — a timeout, a refused connection, a 5xx — hands
  the call to the next candidate, and the local tier is the last resort. A 4xx
  is the answer: Forge's overlong repair prompts were refused by LM Studio with
  a 400 and handed on to a larger local model, which kept both model servers
  loaded until the host froze.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.{Config, LLM}

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

    # A local server is asked for its window before the call; these are not LM Studio.
    Bypass.stub(bypass, "GET", "/api/v0/models", &Plug.Conn.resp(&1, 404, ""))
    p
  end

  defp answers(bypass, status, content) do
    test = self()

    Bypass.stub(bypass, "POST", "/v1/chat/completions", fn conn ->
      send(test, {:called, bypass.port})

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

  test "a 400 from the first provider is the answer; the second is never called", %{
    first: first,
    second: second
  } do
    provider("first", "light", 1, first)
    provider("second", "light", 2, second)
    answers(first, 400, "request exceeds the available context size")
    answers(second, 200, "must not be used")

    assert {:error, {:openai_compat, 400, _body}} = LLM.complete("hi", tier: :light)
    first_port = first.port
    second_port = second.port
    assert_received {:called, ^first_port}
    refute_received {:called, ^second_port}
  end

  test "a 4xx never reaches the local tier either", %{first: first, second: second} do
    provider("light-one", "light", 1, first)
    provider("local-one", "local", 1, second)
    answers(first, 429, "quota")
    answers(second, 200, "must not be used")

    assert {:error, {:openai_compat, 429, _}} = LLM.complete("hi", tier: :light)
    second_port = second.port
    refute_received {:called, ^second_port}
  end

  test "a 5xx hands over to the next in the tier", %{first: first, second: second} do
    provider("first", "light", 1, first)
    provider("second", "light", 2, second)
    answers(first, 503, "overloaded")
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

  test "a refused connection hands over", %{first: first, second: second} do
    provider("first", "light", 1, first)
    provider("second", "light", 2, second)
    answers(second, 200, "from second")
    Bypass.down(first)

    assert LLM.complete("hi", tier: :light) == {:ok, "from second"}
  end

  test "a local call past llm.local_timeout_seconds is abandoned and handed over", %{
    second: second
  } do
    {:ok, _} = Config.set("llm.local_timeout_seconds", "1", type: "integer")

    # A server that takes the connection and never answers.
    {:ok, silent} = :gen_tcp.listen(0, active: false)
    {:ok, silent_port} = :inet.port(silent)

    {:ok, _} =
      LLM.create_provider(%{
        name: "slow",
        type: "ollama",
        tier: "local",
        model: "m",
        host: "http://localhost:#{silent_port}",
        enabled: true,
        priority: 1
      })

    provider("quick", "local", 2, second)
    answers(second, 200, "from quick")

    {micros, result} = :timer.tc(fn -> LLM.complete("hi", tier: :local) end)
    Config.delete("llm.local_timeout_seconds")
    :gen_tcp.close(silent)

    assert result == {:ok, "from quick"}
    assert micros < 1_900_000, "the slow call was waited out instead of abandoned"
  end

  test "when every candidate fails transiently, the last failure is the answer", %{
    first: first,
    second: second
  } do
    provider("first", "light", 1, first)
    provider("second", "light", 2, second)
    answers(first, 502, "first failed")
    answers(second, 503, "second failed")

    assert {:error, reason} = LLM.complete("hi", tier: :light)
    assert inspect(reason) =~ "second failed"
  end

  test "a provider asked for by name is the only one tried", %{first: first, second: second} do
    provider("named", "light", 1, first)
    provider("other", "light", 2, second)
    answers(first, 503, "named failed")
    answers(second, 200, "must not be used")

    assert {:error, reason} = LLM.complete("hi", provider: "named")
    assert inspect(reason) =~ "named failed"
  end

  test "with no provider at all, there is no model", %{} do
    assert LLM.complete("hi", tier: :light) == {:error, :no_available_model}
  end
end

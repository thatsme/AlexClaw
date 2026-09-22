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

  alias AlexClaw.{Config, LLM, ProviderHelper}
  alias AlexClaw.LLM.LocalLock

  # Straight to the database: AlexClaw.LLM refuses a second enabled local
  # provider, and these tests describe what the router does when one exists.
  defp provider(name, tier, priority, bypass) do
    p =
      ProviderHelper.insert!(%{
        name: name,
        tier: tier,
        host: "http://localhost:#{bypass.port}",
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

  test "a local call past llm.local_timeout_seconds is abandoned, and no other local is tried", %{
    second: second
  } do
    {:ok, _} = Config.set("llm.local_timeout_seconds", "1", type: "integer")

    # A server that takes the connection and never answers.
    {:ok, silent} = :gen_tcp.listen(0, active: false)
    {:ok, silent_port} = :inet.port(silent)

    ProviderHelper.insert!(%{
      name: "slow",
      type: "ollama",
      host: "http://localhost:#{silent_port}",
      priority: 1
    })

    provider("quick", "local", 2, second)
    answers(second, 200, "must not be used")

    {micros, result} = :timer.tc(fn -> LLM.complete("hi", tier: :local) end)
    Config.delete("llm.local_timeout_seconds")
    :gen_tcp.close(silent)

    assert {:error, {:ollama, %Req.TransportError{reason: :timeout}}} = result
    assert micros < 1_900_000, "the slow call was waited out instead of abandoned"

    second_port = second.port
    refute_received {:called, ^second_port}
  end

  # Two local providers are two model servers on this host. The second loading
  # its own model beside the first is what froze the machine, so a local
  # provider is never the fallback for another one, whatever the failure.
  test "a local provider is never the fallback for another local provider", %{
    first: first,
    second: second
  } do
    provider("local-one", "local", 1, first)
    provider("local-two", "local", 2, second)
    answers(first, 503, "overloaded")
    answers(second, 200, "must not be used")

    assert {:error, {:openai_compat, 503, _}} = LLM.complete("hi", tier: :local)

    first_port = first.port
    second_port = second.port
    assert_received {:called, ^first_port}
    refute_received {:called, ^second_port}
  end

  test "a local call while another is in flight is refused, not queued", %{first: first} do
    provider("local-one", "local", 1, first)
    answers(first, 200, "must not be used")
    test = self()

    holder =
      spawn(fn ->
        send(test, {:acquired, LocalLock.acquire()})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:acquired, :ok}
    assert LLM.complete("hi", tier: :local) == {:error, :local_model_busy}

    first_port = first.port
    refute_received {:called, ^first_port}
    send(holder, :stop)
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

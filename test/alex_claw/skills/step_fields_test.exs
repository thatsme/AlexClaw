defmodule AlexClaw.Skills.StepFieldsTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  # step_fields/0 is what the workflow editor renders. A field listed there and
  # discarded by run/1 is a control that does nothing, so each advertised field
  # is asserted to reach the LLM call or the prompt.

  import Mox

  alias AlexClaw.LLM
  alias AlexClaw.Skills.Conversational
  alias AlexClaw.Skills.Research
  alias AlexClaw.Skills.RSSCollector
  alias Ecto.Adapters.SQL.Sandbox

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    prior = Application.get_env(:alex_claw, :llm_impl)
    Application.put_env(:alex_claw, :llm_impl, LLM.Mock)
    on_exit(fn -> restore_impl(prior) end)

    Mox.stub(LLM.Mock, :embed, fn _text, _opts -> {:ok, List.duplicate(0.0, 768)} end)

    test = self()

    Mox.stub(LLM.Mock, :complete, fn prompt, opts ->
      send(test, {:llm, prompt, opts})
      {:ok, "0.9"}
    end)

    :ok
  end

  defp restore_impl(nil), do: Application.delete_env(:alex_claw, :llm_impl)
  defp restore_impl(prior), do: Application.put_env(:alex_claw, :llm_impl, prior)

  # Research runs a knowledge-search completion of its own before the research
  # call, so the call under test is selected by its prompt rather than by order.
  defp captured(marker) do
    assert_receive {:llm, prompt, opts}, 5_000

    if String.contains?(prompt, marker) do
      {prompt, opts}
    else
      captured(marker)
    end
  end

  describe "research" do
    test "advertises only fields run/1 reads" do
      assert Research.step_fields() == [:llm_tier, :llm_model, :prompt_template, :config]
    end

    test "llm_tier from the step reaches the LLM call" do
      insert_setting("skill.research.tier", "medium", category: "skill.research")

      Research.run(%{input: "q", config: %{}, llm_tier: "heavy", llm_provider: nil})

      {_prompt, opts} = captured("Research query:")
      assert opts[:tier] == :heavy
    end

    test "no llm_tier on the step falls back to the configured default" do
      insert_setting("skill.research.tier", "light", category: "skill.research")

      Research.run(%{input: "q", config: %{}, llm_tier: nil, llm_provider: nil})

      {_prompt, opts} = captured("Research query:")
      assert opts[:tier] == :light
    end

    test "an unknown tier string falls back rather than raising" do
      insert_setting("skill.research.tier", "medium", category: "skill.research")

      Research.run(%{input: "q", config: %{}, llm_tier: "enormous", llm_provider: nil})

      {_prompt, opts} = captured("Research query:")
      assert opts[:tier] == :medium
    end

    test "llm_model from the step reaches the LLM call as the provider" do
      Research.run(%{input: "q", config: %{}, llm_tier: nil, llm_provider: "ollama"})

      {_prompt, opts} = captured("Research query:")
      assert opts[:provider] == "ollama"
    end

    test "prompt_template renders {input} into the query" do
      Research.run(%{
        input: "pgvector",
        config: %{},
        llm_tier: nil,
        llm_provider: nil,
        prompt_template: "Compare {input} against alternatives"
      })

      {prompt, _opts} = captured("Research query:")
      assert prompt =~ "Compare pgvector against alternatives"
    end

    test "an empty template leaves the raw input in charge" do
      Research.run(%{
        input: "pgvector",
        config: %{},
        llm_tier: nil,
        llm_provider: nil,
        prompt_template: ""
      })

      {prompt, _opts} = captured("Research query:")
      assert prompt =~ "pgvector"
    end

    test "no query is still an error" do
      assert {:error, :no_query} =
               Research.run(%{input: nil, config: %{}, llm_tier: nil, llm_provider: nil})
    end
  end

  describe "conversational" do
    test "advertises only fields run/1 reads" do
      assert Conversational.step_fields() == [:llm_tier, :llm_model, :prompt_template, :config]
    end

    test "llm_tier from the step reaches the LLM call" do
      insert_setting("skill.conversational.tier", "light", category: "skill.conversational")

      Conversational.run(%{input: "hi", config: %{}, llm_tier: "medium", llm_provider: nil})

      {_prompt, opts} = captured("User:")
      assert opts[:tier] == :medium
    end

    test "no llm_tier on the step falls back to the configured default" do
      insert_setting("skill.conversational.tier", "heavy", category: "skill.conversational")

      Conversational.run(%{input: "hi", config: %{}, llm_tier: nil, llm_provider: nil})

      {_prompt, opts} = captured("User:")
      assert opts[:tier] == :heavy
    end

    test "llm_model from the step reaches the LLM call as the provider" do
      Conversational.run(%{input: "hi", config: %{}, llm_tier: nil, llm_provider: "lmstudio"})

      {_prompt, opts} = captured("User:")
      assert opts[:provider] == "lmstudio"
    end

    test "prompt_template renders {input} into the message" do
      Conversational.run(%{
        input: "the build failed",
        config: %{},
        llm_tier: nil,
        llm_provider: nil,
        prompt_template: "Summarise for the on-call engineer: {input}"
      })

      {prompt, _opts} = captured("User:")
      assert prompt =~ "Summarise for the on-call engineer: the build failed"
    end

    test "config message is still read when there is no input" do
      Conversational.run(%{
        input: nil,
        config: %{"message" => "from config"},
        llm_tier: nil,
        llm_provider: nil
      })

      {prompt, _opts} = captured("User:")
      assert prompt =~ "from config"
    end
  end

  describe "rss_collector" do
    test "advertises only fields run/1 reads" do
      assert RSSCollector.step_fields() == [:llm_tier, :llm_model, :config]
    end

    test "llm_tier from the step overrides the pinned scoring tier" do
      RSSCollector.run(feed_args(llm_tier: "heavy"))

      {_prompt, opts} = captured("relevance scorer")
      assert opts[:tier] == :heavy
    end

    test "scoring stays on the light tier when the step sets none" do
      RSSCollector.run(feed_args(llm_tier: nil))

      {_prompt, opts} = captured("relevance scorer")
      assert opts[:tier] == :light
    end

    test "llm_model from the step reaches the scoring call as the provider" do
      RSSCollector.run(feed_args(llm_tier: nil, llm_provider: "ollama"))

      {_prompt, opts} = captured("relevance scorer")
      assert opts[:provider] == "ollama"
    end
  end

  defp feed_args(opts) do
    bypass = Bypass.open()

    xml = """
    <?xml version="1.0"?>
    <rss version="2.0">
      <channel>
        <item>
          <title>Step field probe</title>
          <link>https://example.com/probe-#{System.unique_integer([:positive])}</link>
          <description>probe</description>
          <pubDate>#{Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S +0000")}</pubDate>
        </item>
      </channel>
    </rss>
    """

    Bypass.expect(bypass, "GET", "/feed.xml", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/xml")
      |> Plug.Conn.resp(200, xml)
    end)

    resource = %{
      name: "Probe Feed",
      type: "rss_feed",
      url: "http://localhost:#{bypass.port}/feed.xml",
      enabled: true
    }

    %{
      resources: [resource],
      config: %{"threshold" => 0.0},
      llm_tier: Keyword.get(opts, :llm_tier),
      llm_provider: Keyword.get(opts, :llm_provider)
    }
  end
end

defmodule AlexClaw.Workflows.LLMTransformCitationsTest do
  @moduledoc """
  Links in a summary come from the feed, never from the model
  (reports/DIGEST_LINKS_FACTS.md; 0.3.52).

  Feed content is untrusted. A model that writes URLs can mangle them, and a
  feed item can carry text telling the model which link to include — a
  phishing link delivered to Telegram by the agent itself. So:

  - when `llm_transform`'s input is a list of items (a JSON list, or an
    object with "items") that carry a "link", the model sees them numbered —
    `[1] title — summary` — and NO URL; the prompt gains one instruction:
    cite items by their number in brackets and write no URLs;
  - in the reply, each `[n]` becomes a Markdown link to item n's own link;
  - a `[n]` that matches no item is removed; any URL the model wrote is
    removed;
  - input that is not a list of linked items is handled exactly as before.

  Existing prompts keep working: the instruction is added by the skill, so
  no stored workflow needs editing.
  """
  use ExUnit.Case, async: false
  @moduletag :unit

  alias AlexClaw.Workflows.LLMTransform
  alias AlexClawTest.LLMMock

  setup ctx do
    LLMMock.use_mock(ctx)
    test_pid = self()

    # Capture the prompt the model is given, whichever entry point is used.
    capture = fn prompt ->
      send(test_pid, {:prompt, prompt})
    end

    %{capture: capture}
  end

  @items [
    %{
      "feed" => "HN",
      "title" => "Alpha released",
      "summary" => "About alpha.",
      "link" => "https://a.example/1"
    },
    %{
      "feed" => "HN",
      "title" => "Beta fixed",
      "summary" => "About beta.",
      "link" => "https://b.example/2"
    }
  ]

  defp reply_with(text, capture) do
    Mox.stub(AlexClaw.LLM.Mock, :complete, fn prompt, _opts ->
      capture.(prompt)
      {:ok, text}
    end)

    Mox.stub(AlexClaw.LLM.Mock, :complete_fitted, fn builder, _opts ->
      # The builder is fn budget -> {:ok, prompt} | {:error, _}.
      {:ok, prompt} = builder.(100_000)
      capture.(prompt)
      {:ok, text}
    end)
  end

  # The template is a top-level arg (prompt_template), not a config key.
  defp transform(input) do
    LLMTransform.run(%{
      input: input,
      resources: [],
      config: %{},
      prompt_template: "Summarise these news items:\n{input}"
    })
  end

  defp output({:ok, output, _branch}), do: output

  describe "what the model is given" do
    test "numbered items, no URLs, and the instruction to cite by number", %{capture: capture} do
      reply_with("Nothing to say.", capture)
      transform(Jason.encode!(%{"items" => @items}))

      assert_receive {:prompt, prompt}
      assert prompt =~ "[1] Alpha released"
      assert prompt =~ "[2] Beta fixed"
      refute prompt =~ "https://", "a URL reached the model: #{prompt}"
      assert prompt =~ ~r/cite/i
      assert prompt =~ ~r/no URLs|not write URLs|do not include URLs/i
    end

    test "a bare JSON list of items is recognised too", %{capture: capture} do
      reply_with("ok", capture)
      transform(Jason.encode!(@items))

      assert_receive {:prompt, prompt}
      assert prompt =~ "[1] Alpha released"
      refute prompt =~ "https://"
    end

    # rss_fetch's items carry "description" (often HTML), not "summary". The
    # model must still get the text — stripped of HTML and URLs — or the
    # citation change would silently give it less than it had before.
    test "an item without a summary gives its description, as plain text", %{capture: capture} do
      reply_with("ok", capture)

      items = [
        %{
          "title" => "Gamma",
          "description" => ~s(<p>About <b>gamma</b>. <a href="https://g.example/x">more</a></p>),
          "link" => "https://g.example/1"
        }
      ]

      transform(Jason.encode!(items))

      assert_receive {:prompt, prompt}
      assert prompt =~ "[1] Gamma"
      assert prompt =~ "About gamma"
      refute prompt =~ "<"
      refute prompt =~ "https://"
    end
  end

  describe "what comes out" do
    test "each [n] becomes a link to item n's own link", %{capture: capture} do
      reply_with("• Alpha shipped [1]\n• Beta got fixed [2]", capture)
      out = output(transform(Jason.encode!(%{"items" => @items})))

      assert out =~ "(https://a.example/1)"
      assert out =~ "(https://b.example/2)"
      refute out =~ "[1]"
      refute out =~ "[2]"
    end

    test "a citation that matches no item is removed", %{capture: capture} do
      reply_with("• Something [7]", capture)
      out = output(transform(Jason.encode!(%{"items" => @items})))

      refute out =~ "[7]"
      refute out =~ "http"
    end

    test "a URL the model wrote itself is removed", %{capture: capture} do
      reply_with("• Alpha [1] — details at https://evil.example/login", capture)
      out = output(transform(Jason.encode!(%{"items" => @items})))

      assert out =~ "https://a.example/1"
      refute out =~ "evil.example", "a model-written URL reached the output: #{out}"
    end
  end

  describe "input that is not a list of linked items" do
    test "is substituted and returned exactly as before", %{capture: capture} do
      reply_with("A summary with https://keep.example in it.", capture)
      out = output(transform("plain text about something"))

      assert_receive {:prompt, prompt}
      assert prompt =~ "plain text about something"
      refute prompt =~ ~r/cite/i
      assert out == "A summary with https://keep.example in it."
    end
  end
end

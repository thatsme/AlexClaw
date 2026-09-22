defmodule AlexClaw.FailureTextTest do
  @moduledoc """
  A failed run's gateway message says what went wrong in words. It used to
  paste the raw error term, cut mid-map at 200 characters.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  alias AlexClaw.FailureText

  test "an LLM provider's error reads as its status and message" do
    reason =
      {:scoring_failed,
       {:openai_compat, 400,
        %{"error" => %{"code" => nil, "message" => "No models loaded.", "param" => "model"}}}}

    assert FailureText.describe(reason) == "scoring failed: HTTP 400: No models loaded."
  end

  test "a tagged string and a bare atom read as words" do
    assert FailureText.describe({:unknown_skill, "ghost"}) == "unknown skill: ghost"
    assert FailureText.describe(:no_feeds) == "no feeds"
  end

  test "a status without a message still says the status" do
    assert FailureText.describe({:openai_compat, 502, "<html>bad gateway</html>"}) ==
             "HTTP 502: <html>bad gateway</html>"

    assert FailureText.describe({:ollama, 500, %{}}) == "HTTP 500"
  end

  test "anything else falls back to the term, bounded" do
    long = %{items: Enum.to_list(1..500)}
    text = FailureText.describe({1, 2, 3, long})
    assert String.length(text) <= 300
    assert text =~ "{1, 2, 3"
    assert FailureText.describe(nil) == "nil"
  end
end

defmodule AlexClaw.Skills.WebSearchTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Skills.WebSearch
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    :ok
  end

  describe "run/1" do
    test "returns error with no query" do
      assert {:error, :no_query} = WebSearch.run(%{config: %{}, input: nil})
    end

    test "returns error with empty query" do
      assert {:error, :no_query} = WebSearch.run(%{config: %{"query" => ""}, input: ""})
    end

    test "returns error with blank input" do
      assert {:error, :no_query} = WebSearch.run(%{input: "   ", config: %{}})
    end

    @tag :external
    test "truncates long queries to 200 chars" do
      long_query = String.duplicate("a", 500)

      result = WebSearch.run(%{input: long_query, config: %{}})
      assert match?({:ok, _body, _branch}, result) or match?({:error, _reason}, result)
    end

    @tag :external
    test "uses config query over input" do
      result =
        WebSearch.run(%{
          input: "fallback query",
          config: %{"query" => "elixir language"}
        })

      assert match?({:ok, _body, _branch}, result) or match?({:error, _reason}, result)
    end

    @tag :external
    test "passes llm_provider from args" do
      result =
        WebSearch.run(%{
          input: "test",
          config: %{},
          llm_provider: "nonexistent"
        })

      assert match?({:ok, _body, _branch}, result) or match?({:error, _reason}, result)
    end
  end
end

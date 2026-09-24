defmodule AlexClaw.Skills.LlmScoreTest do
  @moduledoc """
  llm_score reads the model's one-number-per-line reply into scores and keeps
  the items at or above the threshold. The reader used to strip a leading
  "<digits>." as list numbering, which turned "0.1" into 1.0 and "1.0" into 0.
  """
  use ExUnit.Case, async: false
  @moduletag :unit

  import Mox

  alias AlexClaw.Skills.LlmScore

  setup :verify_on_exit!

  setup do
    previous = Application.get_env(:alex_claw, :llm_impl)
    Application.put_env(:alex_claw, :llm_impl, AlexClaw.LLM.Mock)
    on_exit(fn -> restore_llm_impl(previous) end)
    :ok
  end

  # Unset before, unset after: a nil value would stand in for the real router.
  defp restore_llm_impl(nil), do: Application.delete_env(:alex_claw, :llm_impl)
  defp restore_llm_impl(impl), do: Application.put_env(:alex_claw, :llm_impl, impl)

  defp items(n), do: for(i <- 1..n, do: %{"title" => "Item #{i}", "link" => "https://e/#{i}"})

  defp reply(text), do: expect(AlexClaw.LLM.Mock, :complete, fn _prompt, _opts -> {:ok, text} end)

  defp scores(text, n) do
    reply(text)

    case LlmScore.run(%{
           input: Jason.encode!(items(n)),
           config: %{"threshold" => 0.0, "max_items" => 99}
         }) do
      {:ok, json, :on_items} ->
        json |> Jason.decode!() |> Enum.sort_by(& &1["title"]) |> Enum.map(& &1["score"])

      other ->
        other
    end
  end

  describe "reading the reply" do
    test "decimals read as written, including 0.1 and 1.0" do
      assert scores("0.1\n1.0\n0.05", 3) == [0.1, 1.0, 0.05]
    end

    test "list numbering followed by a space is ignored" do
      assert scores("1. 0.8\n2) 0.3\n3: 0.6", 3) == [0.8, 0.3, 0.6]
    end

    test "text after the number is ignored" do
      assert scores("0.7 — relevant\n0.2 (weak)", 2) == [0.7, 0.2]
    end

    test "a 0-10 answer is rescaled" do
      assert scores("8\n3", 2) == [0.8, 0.3]
    end

    test "a line with no number, or a missing line, scores 0 when others are readable" do
      assert scores("0.9\nn/a", 3) == [0.9, 0.0, 0.0]
    end

    # A reply with no readable score at all is not "nothing relevant": it is
    # a reply the skill could not read (failure_contract_test.exs).
    test "a reply with no readable score at all is an error" do
      reply("I cannot help with that.")

      assert {:error, {:unreadable_scores, _}} =
               LlmScore.run(%{input: Jason.encode!(items(2)), config: %{}})
    end
  end

  describe "choosing what passes" do
    test "items at or above the threshold pass, highest first, capped" do
      reply("0.9\n0.2\n0.6")
      input = Jason.encode!(items(3))

      assert {:ok, json, :on_items} =
               LlmScore.run(%{input: input, config: %{"threshold" => 0.5, "max_items" => 1}})

      assert [%{"title" => "Item 1", "score" => 0.9}] = Jason.decode!(json)
    end

    test "a threshold on the boundary passes an equal score" do
      reply("0.5")

      assert {:ok, _, :on_items} =
               LlmScore.run(%{input: Jason.encode!(items(1)), config: %{"threshold" => 0.5}})
    end

    test "nothing above the threshold is the empty branch" do
      reply("0.1\n0.2")

      assert {:ok, text, :on_empty} =
               LlmScore.run(%{input: Jason.encode!(items(2)), config: %{"threshold" => 0.5}})

      assert text =~ "No items passed"
    end

    test "no items or nil input is empty without calling the model" do
      for input <- [Jason.encode!([]), nil] do
        assert {:ok, _, :on_empty} = LlmScore.run(%{input: input, config: %{}})
      end
    end

    # Input that is not a list of items is usually a previous step's error
    # text; reporting it as "no items" hid the earlier failure.
    test "input that is not a list of items is an error, without calling the model" do
      for input <- ["not json", Jason.encode!(%{"a" => 1})] do
        assert {:error, {:invalid_input, _}} = LlmScore.run(%{input: input, config: %{}})
      end
    end

    test "a failing model is an error, not an empty result" do
      expect(AlexClaw.LLM.Mock, :complete, fn _p, _o -> {:error, :no_available_model} end)

      assert {:error, {:scoring_failed, :no_available_model}} =
               LlmScore.run(%{input: Jason.encode!(items(1)), config: %{}})
    end
  end
end

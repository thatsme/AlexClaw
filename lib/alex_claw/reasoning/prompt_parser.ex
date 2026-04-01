defmodule AlexClaw.Reasoning.PromptParser do
  @moduledoc """
  Defensive JSON parser for local LLM responses.

  Local models frequently:
  - Wrap JSON in markdown code fences
  - Add preamble text before JSON
  - Add trailing explanation after JSON
  - Return slightly malformed JSON (trailing commas, single quotes)

  This module extracts and validates JSON from messy LLM output.
  """

  require Logger

  @type parse_result :: {:ok, map()} | {:error, :parse_failed, String.t()}

  @spec parse_plan(String.t()) :: {:ok, map()} | {:error, :parse_failed, String.t()}
  def parse_plan(raw) do
    with {:ok, parsed} <- extract_json(raw, :object) do
      cond do
        Map.has_key?(parsed, "error") ->
          {:ok, parsed}

        Map.has_key?(parsed, "steps") and Map.has_key?(parsed, "working_memory") ->
          steps = Map.get(parsed, "steps", [])

          if is_list(steps) do
            normalized = normalize_plan_steps(steps)
            {:ok, Map.put(parsed, "steps", normalized)}
          else
            {:error, :parse_failed, "plan steps is not a list"}
          end

        true ->
          missing = Enum.reject(["steps", "working_memory"], &Map.has_key?(parsed, &1))
          {:error, :parse_failed, "plan response missing keys: #{Enum.join(missing, ", ")}"}
      end
    end
  end

  @spec parse_execution(String.t()) :: {:ok, map()} | {:error, :parse_failed, String.t()}
  def parse_execution(raw) do
    with {:ok, parsed} <- extract_json(raw, :object),
         :ok <- validate_keys(parsed, ["input", "working_memory"], "execution") do
      {:ok, parsed}
    end
  end

  @spec parse_evaluation(String.t()) :: {:ok, map()} | {:error, :parse_failed, String.t()}
  def parse_evaluation(raw) do
    with {:ok, parsed} <- extract_json(raw, :object),
         :ok <- validate_keys(parsed, ["quality", "working_memory"], "evaluation") do
      quality = Map.get(parsed, "quality", "failed")

      if quality in ["good", "partial", "failed"] do
        {:ok, parsed}
      else
        {:ok, Map.put(parsed, "quality", normalize_quality(parsed))}
      end
    end
  end

  @spec parse_decision(String.t()) :: {:ok, map()} | {:error, :parse_failed, String.t()}
  def parse_decision(raw) do
    with {:ok, parsed} <- extract_json(raw, :object),
         :ok <- validate_keys(parsed, ["action", "working_memory"], "decision") do
      action = Map.get(parsed, "action", "")

      if action in ["continue", "adjust", "ask_user", "done", "stuck"] do
        parsed = maybe_normalize_new_plan(parsed)
        {:ok, parsed}
      else
        Logger.warning("[ReasoningParser] Unknown action #{inspect(action)}, treating as continue")
        {:ok, Map.put(parsed, "action", "continue")}
      end
    end
  end

  # --- JSON Extraction ---

  @spec extract_json(String.t(), :object | :array) :: {:ok, map() | list()} | {:error, :parse_failed, String.t()}
  defp extract_json(raw, expected_type) do
    cleaned = strip_fences(raw)

    case Jason.decode(cleaned) do
      {:ok, result} when is_map(result) and expected_type == :object -> {:ok, result}
      {:ok, result} when is_list(result) and expected_type == :array -> {:ok, result}
      {:ok, _} -> {:error, :parse_failed, "expected #{expected_type}, got different type"}
      {:error, _} -> extract_json_fallback(cleaned, expected_type)
    end
  end

  defp extract_json_fallback(text, :object) do
    # Try greedy match first (handles nested objects), then ungreedy as fallback
    case Regex.run(~r/\{[\s\S]*\}/, text) do
      [match] -> try_decode(match, :object)
      nil -> {:error, :parse_failed, "no JSON object found in response"}
    end
  end

  defp extract_json_fallback(text, :array) do
    case Regex.run(~r/\[[\s\S]*\]/, text) do
      [match] -> try_decode(match, :array)
      nil -> {:error, :parse_failed, "no JSON array found in response"}
    end
  end

  defp try_decode(json_str, expected_type) do
    # Try direct decode first
    case Jason.decode(json_str) do
      {:ok, result} when is_map(result) and expected_type == :object -> {:ok, result}
      {:ok, result} when is_list(result) and expected_type == :array -> {:ok, result}
      {:ok, _} -> {:error, :parse_failed, "extracted JSON is not #{expected_type}"}
      {:error, _} ->
        # Try fixing common local model issues
        fixed = fix_common_issues(json_str)

        case Jason.decode(fixed) do
          {:ok, result} when is_map(result) and expected_type == :object -> {:ok, result}
          {:ok, result} when is_list(result) and expected_type == :array -> {:ok, result}
          {:ok, _} -> {:error, :parse_failed, "extracted JSON is not #{expected_type}"}
          {:error, %Jason.DecodeError{} = err} ->
            {:error, :parse_failed, "JSON decode failed: #{Exception.message(err)}"}
        end
    end
  end

  # --- Cleanup Helpers ---

  defp strip_fences(text) do
    text
    |> String.trim()
    |> strip_markdown_fences()
  end

  defp strip_markdown_fences(text) do
    # Match ```json ... ``` or ``` ... ```
    case Regex.run(~r/```(?:json)?\s*\n?([\s\S]*?)```/i, text) do
      [_, content] -> String.trim(content)
      nil -> text
    end
  end

  defp fix_common_issues(json) do
    json
    |> remove_trailing_commas()
    |> fix_single_quotes()
  end

  defp remove_trailing_commas(json) do
    # Remove trailing commas before } or ]
    Regex.replace(~r/,\s*([}\]])/, json, "\\1")
  end

  defp fix_single_quotes(json) do
    # Only attempt if no double quotes present (full single-quote JSON)
    if String.contains?(json, "\"") do
      json
    else
      String.replace(json, "'", "\"")
    end
  end

  # --- Validation Helpers ---

  defp validate_keys(parsed, required_keys, phase) do
    missing = Enum.reject(required_keys, &Map.has_key?(parsed, &1))

    case missing do
      [] -> :ok
      keys -> {:error, :parse_failed, "#{phase} response missing keys: #{Enum.join(keys, ", ")}"}
    end
  end

  defp valid_plan_step?(step) when is_map(step) do
    has_skill?(step)
  end

  defp valid_plan_step?(_), do: false

  defp has_skill?(step) do
    Map.has_key?(step, "skill") or Map.has_key?(step, "tool")
  end

  @doc false
  def normalize_plan_steps(steps) when is_list(steps) do
    Enum.with_index(steps, 1)
    |> Enum.map(fn {step, idx} ->
      step
      |> normalize_key("skill", ["tool", "skill_name"])
      |> normalize_key("input_description", ["query", "input", "description", "reason"])
      |> Map.put_new("step", idx)
    end)
  end

  defp normalize_key(step, target, aliases) do
    case Map.get(step, target) do
      nil ->
        value = Enum.find_value(aliases, fn key -> Map.get(step, key) end)
        if value, do: Map.put(step, target, value), else: step

      _ ->
        step
    end
  end

  defp normalize_quality(parsed) do
    scores =
      ["relevance", "completeness", "usability", "goal_progress"]
      |> Enum.map(&parse_score(Map.get(parsed, &1)))
      |> Enum.reject(&is_nil/1)

    case scores do
      [] -> "failed"
      scores ->
        avg = Enum.sum(scores) / length(scores)
        cond do
          avg >= 3.5 -> "good"
          avg >= 2.0 -> "partial"
          true -> "failed"
        end
    end
  end

  defp maybe_normalize_new_plan(%{"action" => "adjust", "new_plan" => plan} = parsed)
       when is_list(plan) do
    Map.put(parsed, "new_plan", normalize_plan_steps(plan))
  end

  defp maybe_normalize_new_plan(parsed), do: parsed

  defp parse_score(val) when is_number(val), do: val
  defp parse_score(val) when is_binary(val) do
    case Float.parse(val) do
      {n, _} -> n
      :error -> nil
    end
  end
  defp parse_score(_), do: nil
end
